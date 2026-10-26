// Shared workspace contracts, independent of the MCP transport and DOM.
/** Maps tab-navigation keys to wrapped or endpoint indices, returning null for unsupported keys or empty lists. */
export function tabDestination(key, index, count) {
  if (!count) return null;
  if (key === 'ArrowRight') return (index + 1) % count;
  if (key === 'ArrowLeft') return (index - 1 + count) % count;
  if (key === 'Home') return 0;
  if (key === 'End') return count - 1;
  return null;
}

/** Matches trimmed case-insensitive search text against a workspace item name and version. */
export function workspaceMatches(item, query) {
  return `${item.name || ''} ${item.version || ''}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase());
}

/** Clones a suite for duplication while dropping stored identity, revision, project and timestamp fields. */
export function duplicateSuiteDraft(source) {
  const { id, revision, projectId, createdAt, updatedAt, ...suite } = structuredClone(source);
  suite.name = `${suite.name} copy`.slice(0, 160);
  return suite;
}

/** Keeps distinct available comparison selections, fills from run order and limits the result to the requested count. */
export function comparisonSelection(runs, current, count) {
  const available = runs.map(run => run.id);
  const selected = [...new Set(current.filter(id => available.includes(id)))];
  for (const id of available) if (selected.length < count && !selected.includes(id)) selected.push(id);
  return selected.slice(0, count);
}
