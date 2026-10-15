// Save immutable snapshots in order, preserving edits made while a save is in flight.
export function createDraftAutosave({ read, save, applied, status, error, delay = 500 }) {
  let timer, task, version = 0, savedVersion = 0, disposed = false;
  let pauses = 0, resumed, resumeWait;
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
    changed() { version++; status('pending'); clearTimeout(timer); timer = setTimeout(() => drain().catch(error), delay); },
    async flush() { clearTimeout(timer); await drain(); },
    pause() {
      if (!pauses++) resumeWait = new Promise(resolve => { resumed = resolve; });
      let released = false;
      return () => { if (released) return; released = true; if (disposed) return; if (!--pauses) { resumed(); resumed = null; } };
    },
    dispose() { disposed = true; clearTimeout(timer); if (pauses) { pauses = 0; resumed(); resumed = null; } },
  };
}
