import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { runBuildCommand } from '../../server/native-build-process.mjs';

const exists = (path) => access(path).then(() => true, () => false);
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
async function waitFor(check) {
  for (let attempt = 0; attempt < 400; attempt++) {
    if (await check()) return;
    await delay(10);
  }
  throw new Error('Timed out waiting for the test worker');
}

test('cancelled build retains ownership and cleans late output only after compiler exit', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'native-build-drain-'));
  const ready = join(root, 'ready'), exited = join(root, 'exited');
  const output = join(root, 'temporary-output'), lock = join(root, 'building');
  const controller = new AbortController();
  let pid, settled = false;
  t.after(async () => {
    controller.abort();
    if (pid) await waitFor(() => !alive(pid));
    await rm(root, { recursive: true, force: true });
  });
  await writeFile(lock, 'owned');
  const worker = `const fs = require('node:fs');
    process.on('SIGTERM', () => setTimeout(() => {
      fs.writeFileSync(${JSON.stringify(output)}, 'late compiler output');
      fs.writeFileSync(${JSON.stringify(exited)}, 'exited'); process.exit(0);
    }, 200));
    fs.writeFileSync(${JSON.stringify(ready)}, String(process.pid));
    setInterval(() => {}, 1000);`;
  const done = runBuildCommand(process.execPath, ['-e', worker], { signal: controller.signal })
    .finally(async () => {
      settled = true;
      await rm(output, { force: true }); await rm(lock, { force: true });
    }).then(() => null, (error) => error);
  await waitFor(() => exists(ready));
  pid = Number(await readFile(ready, 'utf8'));
  controller.abort();
  await delay(20);
  assert.equal(settled, false, 'Abort notification must not release build ownership');
  assert.equal(await exists(lock), true);
  assert.equal((await done)?.name, 'AbortError');
  assert.equal(await exists(exited), true);
  assert.equal(alive(pid), false);
  assert.equal(await exists(output), false, 'Late output must be removed after the writer has exited');
  assert.equal(await exists(lock), false);
});

test('build process reports success, failure, launch errors, timeout and pre-cancellation', async () => {
  await runBuildCommand(process.execPath, ['-e', 'process.exit(0)']);
  await assert.rejects(runBuildCommand(process.execPath, ['-e', 'process.exit(7)']), /could not compile/);
  await assert.rejects(runBuildCommand('/nonexistent-foundation-evals-test-compiler', []), { code: 'ENOENT' });
  await assert.rejects(runBuildCommand(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { timeoutMs: 50 }), /time limit/);
  await assert.rejects(runBuildCommand(process.execPath, ['-e', 'process.exit(0)'], { signal: AbortSignal.abort() }), /cancelled/);
});

test('cancelled build forces a SIGTERM-resistant compiler to exit before cleanup', { timeout: 12000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'native-build-force-exit-'));
  const ready = join(root, 'ready');
  const controller = new AbortController();
  let pid, aliveAtCleanup;
  t.after(async () => {
    controller.abort();
    if (pid && alive(pid)) process.kill(pid, 'SIGKILL');
    if (pid) await waitFor(() => !alive(pid));
    await rm(root, { recursive: true, force: true });
  });
  const worker = `const fs = require('node:fs');
    process.on('SIGTERM', () => {});
    fs.writeFileSync(${JSON.stringify(ready)}, String(process.pid));
    setInterval(() => {}, 1000);`;
  const done = runBuildCommand(process.execPath, ['-e', worker], { signal: controller.signal })
    .finally(() => { aliveAtCleanup = alive(pid); })
    .then(() => null, (error) => error);
  await waitFor(() => exists(ready));
  pid = Number(await readFile(ready, 'utf8'));
  controller.abort();
  assert.equal((await done)?.name, 'AbortError');
  assert.equal(aliveAtCleanup, false, 'Cleanup must follow forced termination and reaping');
  assert.equal(alive(pid), false);
});

for (const cancellation of [false, true]) {
  test(`${cancellation ? 'cancellation' : 'timeout'} stops compiler subprocesses before releasing ownership`,
    { timeout: 20000, skip: process.platform === 'win32' }, async (t) => {
      const root = await mkdtemp(join(tmpdir(), 'native-build-descendants-'));
      const ready = join(root, 'ready'), late = join(root, 'late');
      const controller = new AbortController();
      let pids = [], done;
      t.after(async () => {
        controller.abort();
        for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch {} }
        await done;
        await rm(root, { recursive: true, force: true });
      });
      const subprocess = `const fs = require('node:fs');
        process.on('SIGTERM', () => {});
        fs.writeFileSync(${JSON.stringify(ready)}, JSON.stringify([process.ppid, process.pid]));
        setTimeout(() => { fs.writeFileSync(${JSON.stringify(late)}, 'late output'); process.exit(0); }, 10000);`;
      const compiler = `require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(subprocess)}],
          { stdio: ['ignore', 'ignore', 2] });
        setInterval(() => {}, 1000);`;
      const started = performance.now();
      done = runBuildCommand(process.execPath, ['-e', compiler],
        { signal: controller.signal, timeoutMs: cancellation ? 15000 : 4000 }).then(() => null, (error) => error);
      await waitFor(() => exists(ready));
      pids = JSON.parse(await readFile(ready, 'utf8'));
      if (cancellation) controller.abort();
      const error = await done;
      assert.ok(performance.now() - started < 7000, 'Compiler descendants must not outlive the stop deadline');
      if (cancellation) assert.equal(error?.name, 'AbortError');
      else assert.match(error?.message ?? '', /time limit/);
      await waitFor(() => pids.every((pid) => !alive(pid)));
      assert.equal(await exists(late), false, 'Stopped subprocess must not write late compiler output');
    });
}

test('cancellation stays active after the compiler driver exits while a subprocess drains',
  { timeout: 15000, skip: process.platform === 'win32' }, async (t) => {
    const root = await mkdtemp(join(tmpdir(), 'native-build-driver-exit-'));
    const ready = join(root, 'ready'), late = join(root, 'late');
    const controller = new AbortController();
    let pids = [], done;
    t.after(async () => {
      controller.abort();
      for (const pid of pids) { try { process.kill(pid, 'SIGKILL'); } catch {} }
      await done;
      await rm(root, { recursive: true, force: true });
    });
    const subprocess = `const fs = require('node:fs');
      process.on('SIGTERM', () => {});
      fs.writeFileSync(${JSON.stringify(ready)}, JSON.stringify([Number(process.argv[1]), process.pid]));
      setTimeout(() => { fs.writeFileSync(${JSON.stringify(late)}, 'late output'); process.exit(0); }, 6000);`;
    const compiler = `require('node:child_process').spawn(process.execPath,
      ['-e', ${JSON.stringify(subprocess)}, String(process.pid)], { stdio: ['ignore', 'ignore', 2] }).unref();`;
    done = runBuildCommand(process.execPath, ['-e', compiler],
      { signal: controller.signal, timeoutMs: 12000 }).then(() => null, (error) => error);
    await waitFor(() => exists(ready));
    pids = JSON.parse(await readFile(ready, 'utf8'));
    await waitFor(() => !alive(pids[0]));
    assert.equal(alive(pids[1]), true, 'Subprocess must still own stderr after the driver exits');
    controller.abort();
    assert.equal((await done)?.name, 'AbortError');
    await waitFor(() => !alive(pids[1]));
    assert.equal(await exists(late), false);
  });
