import test from 'node:test';
import assert from 'node:assert/strict';
import { createStatusPoller } from '../ui/polling.js';

function fixture(refresh) {
  const timers = new Map(), errors = [];
  let sequence = 0, active = true;
  const poller = createStatusPoller({ active: () => active, refresh, error: error => errors.push(error.message),
    schedule: (callback, delay) => { const id = ++sequence; timers.set(id, { callback, delay }); return id; },
    clear: id => timers.delete(id),
  });
  return { poller, errors, timers, stopRun: () => { active = false; },
    async tick() { assert.equal(timers.size, 1); const [id, timer] = timers.entries().next().value; timers.delete(id); await timer.callback(); },
    delay: () => timers.values().next().value?.delay,
  };
}

test('one transient status failure remains visible and polling resumes without a mutation', async () => {
  let requests = 0;
  const f = fixture(async () => { if (++requests === 1) throw new Error('Transport temporarily unavailable'); });
  f.poller.schedule();
  assert.equal(f.delay(), 1800);
  await f.tick();
  assert.deepEqual(f.errors, ['Transport temporarily unavailable']);
  assert.equal(f.delay(), 3600);
  await f.tick();
  assert.equal(requests, 2);
  assert.equal(f.delay(), 1800);
  f.stopRun();
  await f.tick();
  assert.equal(requests, 2);
  assert.equal(f.timers.size, 0);
});

test('repeated status failures use capped backoff and success restores normal cadence', async () => {
  let fail = true;
  const f = fixture(async () => { if (fail) throw new Error('Read failed'); });
  f.poller.schedule();
  for (const delay of [3600, 7200, 14400, 15000, 15000, 15000]) {
    await f.tick();
    assert.equal(f.delay(), delay);
  }
  fail = false;
  await f.tick();
  assert.equal(f.delay(), 1800);
  f.poller.dispose();
  assert.equal(f.timers.size, 0);
});

test('a pending status request does not overlap and teardown prevents rescheduling', async () => {
  let release, calls = 0;
  const f = fixture(() => { calls++; return new Promise(resolve => { release = resolve; }); });
  f.poller.schedule();
  const pending = f.tick();
  f.poller.schedule();
  assert.equal(calls, 1);
  assert.equal(f.timers.size, 0);
  f.poller.dispose();
  release();
  await pending;
  f.poller.schedule();
  assert.equal(f.timers.size, 0);
});

test('terminal run status stops polling after the current read', async () => {
  const f = fixture(async () => f.stopRun());
  f.poller.schedule();
  await f.tick();
  assert.equal(f.timers.size, 0);
});
