/**
 * Creates a debounced save queue that snapshots each draft and preserves edits arriving during a save.
 * The read callback must return the live draft object; applied runs only while that same object remains selected.
 */
export function createDraftAutosave({ read, save, applied, status, error, delay = 500 }) {
  let timer, task, version = 0, savedVersion = 0, disposed = false;
  let pauses = 0, resumed, resumeWait;
  /**
   * Drains unsaved versions serially, waiting for pauses and applying responses only to their original draft.
   * A failed save leaves its version pending and propagates the failure after setting error status.
   */
  async function drain() {
    if (pauses) await resumeWait;
    if (task) return task;
    task = (async () => {
      while (!disposed && savedVersion < version) {
        if (pauses) { await resumeWait; continue; }
        const draft = read(), requested = version;
        if (!draft) { savedVersion = requested; break; }
        const response = await save(structuredClone(draft));
        if (read() === draft) applied(draft, response, requested === version);
        savedVersion = requested;
      }
      status(savedVersion < version ? 'pending' : 'saved');
    })();
    try { await task; } catch (failure) { status('error'); throw failure; } finally { task = null; }
  }
  return {
    /** Marks a new draft version pending and restarts the debounce timer. */
    changed() { version++; status('pending'); clearTimeout(timer); timer = setTimeout(() => drain().catch(error), delay); },
    /** Cancels the debounce delay and waits for the queued draft versions to save. */
    async flush() { clearTimeout(timer); await drain(); },
    /** Pauses snapshot creation until its release callbacks run or disposal releases waiters; each release is idempotent. */
    pause() {
      if (!pauses++) resumeWait = new Promise(resolve => { resumed = resolve; });
      let released = false;
      return () => { if (released) return; released = true; if (disposed) return; if (!--pauses) { resumed(); resumed = null; } };
    },
    /** Stops future drains, clears the debounce timer and releases paused waiters without cancelling an in-flight save. */
    dispose() { disposed = true; clearTimeout(timer); if (pauses) { pauses = 0; resumed(); resumed = null; } },
  };
}
