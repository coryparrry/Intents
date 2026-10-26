/** Identifies a recorded sample by case identifier and repetition. */
export const resultKey = result => `${result.caseId}:${result.repetition}`;
/** Classifies trace errors before pass or fail verdicts, leaving absent verdicts unscored. */
export const outcome = result => result.trace?.error ? 'Error' : result.passed === true ? 'Passed' : result.passed === false ? 'Failed' : 'Unscored';
/** Chooses a recorded case name, readable non-generated identifier or one-based fallback title. */
export function caseTitle(test, index = 0) {
  if (test?.name?.trim() || test?.caseName?.trim() || (test?.appSample || test?.trace?.appSample)?.caseName?.trim()) return test.name?.trim() || test.caseName?.trim() || (test.appSample || test.trace.appSample).caseName.trim();
  const id = test?.id || test?.caseId || '';
  if (id && !/^[a-f\d-]{36}$/i.test(id) && !/^case[- ]?\d+$/i.test(id)) {
    return id.replace(/[-_]/g, ' ').replace(/\b\w/g, letter => letter.toUpperCase());
  }
  return `Case ${index + 1}`;
}
/** Finds the recorded sample name or matching suite case title, falling back to result order. */
export function resultTitle(run, result) {
  let index = run.suite?.cases?.findIndex(test => test.id.toLowerCase() === result.caseId.toLowerCase()) ?? -1;
  if (result.appSample?.caseName || result.trace?.appSample?.caseName) return (result.appSample || result.trace.appSample).caseName;
  if (index >= 0 && run.suite.cases[index].name) return run.suite.cases[index].name;
  if (index < 0) index = [...new Set((run.results || []).map(item => item.caseId))].indexOf(result.caseId);
  return caseTitle(result, Math.max(0, index));
}
/** Checks that a comparison response still matches the request sequence, suite and ordered run selection. */
export function comparisonMatches(request, current) {
  return request.sequence === current.sequence && request.suiteId === current.suiteId && request.runIds.length === current.runIds.length && request.runIds.every((id, index) => id === current.runIds[index]);
}
/** Calculates outcome counts, scored pass rate and available nonnegative latency metrics for a run. */
export function runMetrics(run) {
  const results = run.results || [];
  /** Counts results in the requested displayed outcome category. */
  const count = label => results.filter(result => outcome(result) === label).length;
  const passed = count('Passed'), failed = count('Failed'), errors = count('Error'), unscored = count('Unscored');
  const latencies = results.map(result => result.durationMs).filter(value => Number.isFinite(value) && value >= 0);
  return { total: results.length, planned: (run.suite?.cases?.length || 0) * (run.suite?.repetitions || 1), passed, failed, errors, unscored,
    passRate: results.some(result => typeof result.passed === 'boolean') ? results.filter(result => result.passed === true).length / results.filter(result => typeof result.passed === 'boolean').length : null,
    averageLatency: latencies.length ? latencies.reduce((sum, value) => sum + value, 0) / latencies.length : null,
    longestLatency: latencies.length ? Math.max(...latencies) : null };
}
/** Filters run results by outcome category and case, prompt or response search text. */
export function visibleResults(run, filter = 'All', search = '') {
  const query = search.trim().toLowerCase();
  return (run.results || []).filter((result, index) => {
    const status = outcome(result);
    const matches = filter === 'All' || status === filter || filter === 'Issues' && (status === 'Error' || status === 'Unscored');
    return matches && (!query || [resultTitle(run, result), result.caseId, result.prompt, result.response].join(' ').toLowerCase().includes(query));
  });
}
/** Finds the selected sample in the visible list, falling back to its first result or null. */
export function selectedResult(run, key, visible = run.results || []) {
  return visible.find(result => resultKey(result) === key) || visible[0] || null;
}
/** Flattens recorded transcript wrappers into display roles, text and retained raw entries. */
export function transcriptEntries(result) {
  return (result.trace?.transcript || []).flatMap(entry=>entry.transcript?.entries || entry.entries || [entry]).map((entry, index) => ({
    role: { instructions: 'Instructions', user: 'User', response: 'Model' }[entry.role] || `Entry ${index + 1}`,
    text: Array.isArray(entry.contents) ? entry.contents.filter(part => typeof part.text === 'string').map(part => part.text).join('\n') : entry.text || '',
    raw: entry
  }));
}
/** Formats recorded transcript JSON from plain, base64 or structured sources, falling back to transcript entries. */
export function transcriptJSONText(result) {
  const sample=result.appSample || result.trace?.appSample;
  const raw=result.trace?.rawTranscriptJSON || result.trace?.transcriptJSON || sample?.featureTrace?.transcript?.transcriptJSON;
  if (typeof raw==='string') {
    try { return JSON.stringify(JSON.parse(raw),null,2); } catch {}
    try { return JSON.stringify(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(raw),letter=>letter.charCodeAt(0)))),null,2); } catch {}
  } else if(raw) return JSON.stringify(raw,null,2);
  const document=(result.trace?.transcript || []).find(item=>item.transcript?.entries || item.entries);
  return document ? JSON.stringify(document,null,2) : '';
}

/** Returns the original application run for export or wraps a flat run in the versioned trace format. */
export function traceExportPayload(run) {return run.appRun || {format:'apple-foundation-evals-trace',version:1,run};}
