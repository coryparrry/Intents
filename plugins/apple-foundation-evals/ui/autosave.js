// Save immutable snapshots in order, preserving edits made while a save is in flight.
export function createDraftAutosave({ read, save, applied, status, error, delay = 500 }) {
  let timer, task, version = 0, savedVersion = 0, disposed = false;
  async function drain() {
    if (task) return task;
    task = (async () => {
      while (!disposed && savedVersion < version) {
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
    dispose() { disposed = true; clearTimeout(timer); },
  };
}
