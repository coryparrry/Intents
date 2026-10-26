/**
 * Creates a single-flight status poller with capped exponential backoff after failed refreshes.
 * Call the returned schedule method to start status polling; explicit callers retain ownership of mutations.
 */
export function createStatusPoller({ active, refresh, error, disposed = () => false,
  delay = 1800, maximumDelay = 15000, schedule = setTimeout, clear = clearTimeout }) {
  let timer, running = false, stopped = false, failures = 0;
  /** Replaces the pending timer only while active, undisposed and idle, using the current failure backoff. */
  function scheduleNext() {
    clear(timer);
    timer = undefined;
    if (stopped || disposed() || !active() || running) return;
    const wait = Math.min(maximumDelay, delay * 2 ** Math.min(failures, 16));
    timer = schedule(tick, wait);
  }
  /** Refreshes status once, records failure backoff and schedules the next active read after completion. */
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
    /** Stops future polls and clears the timer without cancelling an already-running refresh. */
    dispose() { stopped = true; clear(timer); timer = undefined; },
  };
}
