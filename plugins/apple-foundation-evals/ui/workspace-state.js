/**
 * Tracks navigation and per-channel request generations for rejecting stale asynchronous UI updates.
 * A captured ticket remains current only while its navigation and optional channel sequence still match and state is not disposed.
 */
export function createWorkspaceScope(state) {
  let navigation = 0;
  const requests = new Map();
  /** Captures navigation ownership and advances the request generation when a channel is supplied. */
  const capture = (channel) => {
    const sequence = channel ? (requests.get(channel) || 0) + 1 : 0;
    if (channel) requests.set(channel, sequence);
    return { navigation, channel, sequence };
  };
  return {
    capture,
    /** Invalidates earlier navigation tickets and returns a ticket for the new navigation generation. */
    navigate() { navigation++; return capture(); },
    /** Checks disposal, navigation generation and any channel sequence before a response may update state. */
    current(ticket) {
      return !state.disposed && ticket.navigation === navigation &&
        (!ticket.channel || requests.get(ticket.channel) === ticket.sequence);
    },
  };
}
/** Clears suite comparison evidence while retaining a running experiment separately for continued tracking. */
export function resetSuiteEvidence(state) {
  if (state.experiment?.status === 'running') state.activeExperiment = state.experiment;
  state.comparison = null;
  state.compareIds = [];
  state.experiments = null;
  state.experiment = null;
  state.experimentSummary = null;
}
/** Compares serialized suite values to detect whether local content changed. */
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);
/** Detects non-null non-array objects eligible for recursive property merging. */
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
/**
 * Merges a saved mutation into current edits, preserving local changes and removals while appending remote additions by identifier.
 * Server revision, update time and project ownership replace local metadata; the result reports whether another save is needed.
 */
export function mergeSuiteMutation(base, edited, saved) {
  /** Recursively takes remote values for unchanged content while retaining edited values, local array order and deletions. */
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
/**
 * Serializes suite mutations with autosave, flushing pending edits before snapshotting and pausing further saves during the request.
 * The result merges only into the original selected draft; pause release and queue cleanup run after success or failure.
 * The read callback must retain draft identity; applied receives the saved suite and whether merged local edits remain.
 */
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
