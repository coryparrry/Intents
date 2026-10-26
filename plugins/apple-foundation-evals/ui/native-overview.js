/** Classifies the latest suite run using completion, stale-evidence and recorded outcome counts. */
export function appSuiteHealth(suite, runs) {
  const latest = runs.filter(run => run.suiteId === suite.id).sort((a,b) => Date.parse(b.finishedAt || b.startedAt) - Date.parse(a.finishedAt || a.startedAt))[0];
  if (!latest) return { kind:'unassessed', title:'Not yet assessed', latest:null };
  if (latest.health?.staleEvidence || latest.health?.currentAssessment === 'stale') return { kind:'attention', title:'Definition changed', latest };
  if (latest.status !== 'completed' || latest.health?.currentAssessment === 'incomplete' || latest.failed > 0 || latest.errors > 0) return { kind:'attention', title:latest.status === 'running' ? 'Running' : 'Needs attention', latest };
  if (!latest.passed) return { kind:'unassessed', title:'Not yet assessed', latest };
  return {kind:'passing',title:'Responses passed',latest};
}
