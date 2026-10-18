// Only status reads are retried. Mutations remain owned by their explicit callers.
export function createStatusPoller({ active, refresh, error, disposed = () => false,
  delay = 1800, maximumDelay = 15000, schedule = setTimeout, clear = clearTimeout }) {
  let timer, running = false, stopped = false, failures = 0;
  function scheduleNext() {
    clear(timer);
    timer = undefined;
    if (stopped || disposed() || !active() || running) return;
    const wait = Math.min(maximumDelay, delay * 2 ** Math.min(failures, 16));
    timer = schedule(tick, wait);
  }
  async function tick() {
    timer = undefined;
    if (stopped || disposed() || !active()) return;
    running = true;
    try {
      await refresh();
      failures = 0;
    } catch (failure) {
      failures = Math.min(failures + 1, 16);
      if (!stopped && !disposed()) error(failure);
    } finally {
      running = false;
      scheduleNext();
    }
  }
  return {
    schedule: scheduleNext,
    dispose() { stopped = true; clear(timer); timer = undefined; },
  };
}
