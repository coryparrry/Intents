export function appSuiteHealth(suite, runs) {
  const latest = runs.filter(run => run.suiteId === suite.id).sort((a,b) => Date.parse(b.finishedAt || b.startedAt) - Date.parse(a.finishedAt || a.startedAt))[0];
  if (!latest) return { kind:'unassessed', title:'Not yet assessed', latest:null };
  if (latest.health?.staleEvidence || latest.health?.currentAssessment === 'stale') return { kind:'attention', title:'Definition changed', latest };
  if (latest.status !== 'completed' || latest.health?.currentAssessment === 'incomplete' || latest.failed > 0 || latest.errors > 0) return { kind:'attention', title:latest.status === 'running' ? 'Running' : 'Needs attention', latest };
  if (!latest.passed) return { kind:'unassessed', title:'Not yet assessed', latest };
  return {kind:'passing',title:'Responses passed',latest};
}

export function renderNativeOverview(ctx) {
  const { state, node, button } = ctx;
  const project = state.projects.find(item => item.id === state.projectId);
  const assessments = state.suites.map(suite => ({ suite, ...appSuiteHealth(suite, state.runs) }));
  const page = node('div', null, 'page overview-page');
  const header = node('div', null, 'overview-heading');
  const title = node('div');
  title.append(node('h1', project?.name || 'Local evaluations'), node('p', 'Foundation Models evaluation workspace', 'overview-subtitle'));
  header.append(title, button('New Suite', ctx.createSuite, 'secondary'));
  page.append(header);

  const summary = node('div', null, 'project-summary');
  for (const [name, count, kind] of [
    ['Passing', assessments.filter(item => item.kind === 'passing').length, 'passing'],
    ['Needs attention', assessments.filter(item => item.kind === 'attention').length, 'attention'],
    ['Not assessed', assessments.filter(item => item.kind === 'unassessed').length, 'unassessed'],
    ['Cases', state.suites.reduce((sum, suite) => sum + suite.cases.length, 0), 'cases']
  ]) {
    const item = node('div', null, `summary-stat ${kind}`);
    item.append(node('strong', count), node('span', name));
    summary.append(item);
  }
  page.append(summary);

  const suites = node('section', null, 'workspace-table');
  const tools = node('div', null, 'list-toolbar');
  const heading = node('h2', 'Suites');
  heading.append(node('span', state.suites.length, 'count'));
  const search = node('input');
  search.type = 'search'; search.placeholder = 'Find a suite'; search.setAttribute('aria-label', 'Find a suite'); search.value = state.suiteSearch || '';
  const attention = button('Needs attention', () => { state.onlyAttention = !state.onlyAttention; ctx.renderMain(); }, 'list-filter');
  attention.setAttribute('aria-pressed', String(!!state.onlyAttention));
  tools.append(heading, attention, search); suites.append(tools);
  const scroll = node('div', null, 'table-scroll');
  const table = node('table', null, 'suite-table');
  table.setAttribute('aria-label', 'Evaluation suites');
  const head = node('thead'), labels = node('tr');
  for (const label of ['Suite', 'Cases', 'Scoring', 'Latest check', 'Status', '']) labels.append(node('th', label));
  head.append(labels); table.append(head);
  const body = node('tbody'); table.append(body); scroll.append(table); suites.append(scroll);
  const empty = node('p', 'No matching suites.', 'hint padded');
  suites.append(empty);
  function renderRows() {
    body.replaceChildren();
    const visible = assessments.filter(item => (!state.onlyAttention || item.kind === 'attention') && item.suite.name.toLocaleLowerCase().includes((state.suiteSearch || '').toLocaleLowerCase()));
    empty.hidden = visible.length > 0;
    for (const item of visible) {
      const row = node('tr'), name = node('td');
      const open = button(item.suite.name, () => ctx.selectSuite(item.suite), 'suite-name');
      open.prepend(ctx.icon('suite')); name.append(open);
      const status = node('td'); status.append(node('span', item.title, `table-status ${item.kind}`));
      const action = node('td'), run = button('', () => ctx.runSuite(item.suite), 'run-suite-button', ctx.active());
      run.setAttribute('aria-label', `Run ${item.suite.name}`); run.append(ctx.icon('play')); action.append(run);
      row.append(name, node('td', item.suite.cases.length), node('td', ctx.scoringLabel(item.suite.scoringMode)), node('td', item.latest ? ctx.date(item.latest.finishedAt || item.latest.startedAt) : '—'), status, action);
      body.append(row);
    }
  }
  search.oninput = () => { state.suiteSearch = search.value; renderRows(); };
  renderRows(); page.append(suites);

  const recent = node('section', null, 'recent-runs');
  recent.append(node('h2', 'Recent runs'));
  const runs = state.runs.filter(run => run.status !== 'running').slice(0, 5);
  for (const run of runs) {
    const row = button('', () => ctx.selectRun(run.id, 'report'), 'recent-run-row');
    row.append(ctx.icon('trace'), node('strong', run.suiteName), node('span', ctx.date(run.finishedAt || run.startedAt)), node('small', `${run.passed} passed · ${run.failed} failed · ${run.errors || 0} errors`));
    recent.append(row);
  }
  if (!runs.length) recent.append(node('p', 'Run a suite to collect responses and execution traces.', 'hint'));
  page.append(recent);
  return page;
}
