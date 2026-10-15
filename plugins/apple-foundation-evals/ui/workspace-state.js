// Async work may finish for a record after the user has moved elsewhere.
export function createWorkspaceScope(state) {
  let navigation = 0;
  const requests = new Map();
  const capture = (channel) => {
    const sequence = channel ? (requests.get(channel) || 0) + 1 : 0;
    if (channel) requests.set(channel, sequence);
    return { navigation, channel, sequence };
  };
  return {
    capture,
    navigate() { navigation++; return capture(); },
    current(ticket) {
      return !state.disposed && ticket.navigation === navigation &&
        (!ticket.channel || requests.get(ticket.channel) === ticket.sequence);
    },
  };
}
export function resetSuiteEvidence(state) {
  if (state.experiment?.status === 'running') state.activeExperiment = state.experiment;
  state.comparison = null;
  state.compareIds = [];
  state.experiments = null;
  state.experiment = null;
  state.experimentSummary = null;
}
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
// Merge server additions without dropping edits/removals made during the operation.
export function mergeSuiteMutation(base, edited, saved) {
  const merge = (before, local, remote) => {
    if (equal(before, local)) return structuredClone(remote);
    if (Array.isArray(before) && Array.isArray(local) && Array.isArray(remote) &&
        [...before, ...local, ...remote].every(item => record(item) && typeof item.id === 'string')) {
      const originals = new Map(before.map(item => [item.id, item]));
      const updates = new Map(remote.map(item => [item.id, item]));
      const result = local.map(item => originals.has(item.id) && updates.has(item.id)
        ? merge(originals.get(item.id), item, updates.get(item.id)) : structuredClone(item));
      const localIDs = new Set(local.map(item => item.id));
      for (const item of remote) if (!originals.has(item.id) && !localIDs.has(item.id)) result.push(structuredClone(item));
      return result;
    }
    if (record(before) && record(local) && record(remote)) {
      const result = {};
      for (const key of new Set([...Object.keys(local), ...Object.keys(remote)])) {
        if (!(key in local) && key in before) continue;
        const value = merge(before[key], local[key], remote[key]);
        if (value !== undefined) result[key] = value;
      }
      return result;
    }
    return structuredClone(local);
  };
  const merged = merge(base, edited, saved);
  for (const key of ['revision', 'updatedAt', 'projectId']) {
    if (saved[key] === undefined) delete merged[key]; else merged[key] = saved[key];
  }
  return { suite: merged, edited: !equal(merged, saved) };
}
// Include the initial flush in the queue: several callers can otherwise wake
// from the same pending save and snapshot one revision before either pauses it.
const mutationTails = new WeakMap();
export async function mutateSuiteDraft({ autosave, read, mutate, applied, changed }) {
  const draft = read(), previous = mutationTails.get(autosave);
  const task = (async () => {
    if (previous) await previous.catch(() => {});
    await autosave.flush();
    if (!draft || read() !== draft) return null;
    const base = structuredClone(draft), resume = autosave.pause();
    try {
      const result = await mutate(base);
      if (read() === draft) {
        const merged = mergeSuiteMutation(base, draft, result.suite);
        for (const key of Object.keys(draft)) delete draft[key];
        Object.assign(draft, merged.suite);
        applied(result.suite, merged.edited);
        if (merged.edited) changed();
      }
      return result;
    } finally { resume(); }
  })();
  mutationTails.set(autosave, task);
  try { return await task; }
  finally { if (mutationTails.get(autosave) === task) mutationTails.delete(autosave); }
}
