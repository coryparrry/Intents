// The case editor follows SuiteCasesView and ConversationConfigurationEditor.
export const APP_SCORING = { modelJudge: 'AI rubric', exactMatch: 'Exact text', containsExpected: 'Contains text', review: 'Collect only' };
export function newAppSuite(projectId) {
  return { id: crypto.randomUUID(), projectId, name: 'My Foundation Model Eval', version: 'v1', instructions: 'Answer accurately and concisely.',
    criteria: 'The response is factually correct or consistent with the supplied reference answer.\nThe response directly answers the prompt without irrelevant material.\nThe response follows every requested format, tone, and length constraint.',
    scoringMode: 'modelJudge', repetitions: 1, temperature: .7, maxTokens: 1024, modelConfiguration: { provider: 'onDevice', samplingMode: 'automatic', temperatureEnabled: false, temperature: .7, seedEnabled: false, seed: 42, topK: 40, probabilityThreshold: .9, maximumResponseTokens: 1024, maximumToolCalls: 2, referenceMode: 'inline', contextPolicy: 'fitReferences', reasoningLevel: 'automatic', customization: { saveFullTranscript: true } },
    features: { tools: [], outputFields: [], outputSchemaDefinitions: [], profile: { enabled: false }, prewarm: false, streamResponse: false }, attachments: [],
    cases: [{ id: crypto.randomUUID(), name: 'Example', prompt: 'Explain why the sky appears blue in two sentences.', expected: '', scoring: 'none', conversation: { setupTurns: [], historyPolicy: 'keepAll', retainedTurnCount: 2 }, fieldAssertions: [] }] };
}
export function appSelect(ctx, label, object, key, options, onChange) {
  const wrap = ctx.node('label', label, 'form-control'), input = ctx.node('select'); input.setAttribute('aria-label', label);
  for (const [value, title] of options) input.append(new Option(title, value));
  input.value = object[key] ?? options[0]?.[0];
  input.onchange = () => { object[key] = input.value; ctx.changed(); if (onChange) onChange(); };
  wrap.append(input); return wrap;
}
export function appToggle(ctx, label, object, key, onChange) {
  const wrap = ctx.node('label', null, 'toggle-control'), input = ctx.node('input'); input.type = 'checkbox'; input.checked = !!object[key];
  input.onchange = () => { object[key] = input.checked; ctx.changed(); if (onChange) onChange(); }; wrap.append(input, ctx.node('span', label)); return wrap;
}
export function appNumber(ctx, label, object, key, min, max, step = 1, optional = false) {
  const wrap = ctx.node('label', label, 'form-control'), input = ctx.node('input'); input.type = 'number'; input.min = min; input.max = max; input.step = step; input.value = object[key] ?? ''; input.setAttribute('aria-label', label);
  input.oninput = () => { if (optional && !input.value) delete object[key]; else object[key] = Number(input.value); ctx.changed(); };
  wrap.append(input); return wrap;
}
export function appDisclosure(ctx, title, detail, content, key) {
  const wrap = ctx.node('details', null, 'optional-section'); wrap.open = !!ctx.state.disclosures?.[key];
  const summary = ctx.node('summary'), text = ctx.node('span'); text.append(ctx.node('strong', title), ctx.node('small', detail)); summary.append(ctx.icon('chevron'), text); wrap.append(summary, content);
  wrap.ontoggle = () => { (ctx.state.disclosures ||= {})[key] = wrap.open; }; return wrap;
}
export function appSection(ctx, title, detail, contents, symbol = 'file') {
  const section = ctx.node('section', null, 'surface setup-section'), header = ctx.node('div', null, 'section-heading'), text = ctx.node('div');
  text.append(ctx.node('h2', title)); if (detail) text.append(ctx.node('p', detail)); header.append(ctx.icon(symbol), text); section.append(header);
  const content = ctx.node('div', null, 'section-body'); content.append(...contents); section.append(content); return section;
}
export function appSchemaField() { return { id: crypto.randomUUID(), name: '', description: '', type: 'string', isOptional: false, children: [], enumValues: [], constraints: { stringPattern: '' }, referenceName: '', representNilExplicitlyInGeneratedContent: false }; }
export function appSchemaEditor(ctx, fields, label = 'Fields', depth = 0) {
  const list = ctx.node('div', null, 'schema-editor');
  for (const item of fields) {
    item.children ||= []; item.enumValues ||= []; item.constraints ||= { stringPattern: '' };
    const card = ctx.node('div', null, 'schema-field'), header = ctx.node('div', null, 'form-grid');
    header.append(ctx.field('Field name', item.name, value => item.name = value), appSelect(ctx, 'Type', item, 'type', [['string','Text'],['integer','Integer'],['number','Number'],['boolean','True or false'],['enumeration','Choice'],['object','Object'],['array','Array'],['null','Null'],['union','One of'],['reference','Reference'],['imageReference','Image reference']], ctx.renderMain));
    card.append(header, ctx.field('Description', item.description, value => item.description = value), appToggle(ctx, 'Optional', item, 'isOptional'));
    if (item.isOptional) card.append(appToggle(ctx, 'Represent nil explicitly', item, 'representNilExplicitlyInGeneratedContent'));
    if (item.type === 'reference') card.append(ctx.field('Definition name', item.referenceName, value => item.referenceName = value));
    if (item.type === 'enumeration') {
      card.append(ctx.field('Choices (one per line)', item.enumValues.map(value => value.value).join('\n'), value => { item.enumValues = value.split('\n').map((text, index) => ({ id: item.enumValues[index]?.id || crypto.randomUUID(), value: text })); }, true, 'compact-editor'));
    }
    if (['object','array','union'].includes(item.type) && depth < 4) card.append(appSchemaEditor(ctx, item.children, item.type === 'array' ? 'Element type' : item.type === 'union' ? 'Alternatives' : 'Nested fields', depth + 1));
    const checks = ctx.node('div', null, 'form-grid');
    if (item.type === 'string') checks.append(ctx.field('Regular expression', item.constraints.stringPattern || '', value => item.constraints.stringPattern = value));
    if (['integer','number','array'].includes(item.type)) {
      const keys = item.type === 'integer' ? ['integerMinimum','integerMaximum'] : item.type === 'number' ? ['numberMinimum','numberMaximum'] : ['arrayMinimumCount','arrayMaximumCount'];
      checks.append(appNumber(ctx, 'Minimum', item.constraints, keys[0], item.type === 'array' ? 0 : -1e9, 1e9, item.type === 'number' ? .1 : 1, true), appNumber(ctx, 'Maximum', item.constraints, keys[1], item.type === 'array' ? 0 : -1e9, 1e9, item.type === 'number' ? .1 : 1, true));
    }
    card.append(checks, ctx.button('Remove field', () => { fields.splice(fields.indexOf(item), 1); ctx.changed(); ctx.renderMain(); }, 'quiet danger')); list.append(card);
  }
  list.append(ctx.button(`+ Add ${label === 'Element type' ? 'element type' : label === 'Definitions' ? 'definition' : 'field'}`, () => { fields.push(appSchemaField()); ctx.changed(); ctx.renderMain(); }, 'quiet', fields.length >= 8)); return list;
}
function appFieldChecks(ctx, test) {
  const assertions = test.fieldAssertions ||= [], contents = ctx.node('div', null, 'disclosure-body');
  for (const assertion of assertions) {
    const row = ctx.node('div', null, 'schema-field'); row.append(ctx.field('JSON pointer', assertion.pointer, value => assertion.pointer = value), appSelect(ctx, 'Check', assertion, 'operation', [['exists','Exists'],['equals','Equals JSON value'],['containsText','Contains text'],['minimum','Number ≥'],['maximum','Number ≤']], ctx.renderMain));
    if (assertion.operation !== 'exists') row.append(ctx.field('Expected value', assertion.expectedValue, value => assertion.expectedValue = value));
    row.append(ctx.button('Remove check', () => { assertions.splice(assertions.indexOf(assertion),1); ctx.changed(); ctx.renderMain(); }, 'quiet danger')); contents.append(row);
  }
  contents.append(ctx.button('+ Add check', () => { assertions.push({ id: crypto.randomUUID(), pointer: '', operation: 'exists', expectedValue: '' }); ctx.changed(); ctx.renderMain(); }, 'quiet'));
  return appDisclosure(ctx, 'Field checks', `${assertions.length} checks for structured responses`, contents, `checks-${test.id}`);
}
function appConversation(ctx, test) {
  const config = test.conversation ||= { setupTurns: [], historyPolicy: 'keepAll', retainedTurnCount: 2 }; config.setupTurns ||= [];
  const contents = ctx.node('div', null, 'disclosure-body'); contents.append(ctx.node('p','Run setup turns in the same session before this case’s final prompt.','hint'));
  config.setupTurns.forEach((turn, index) => {
    const row = ctx.node('div', null, 'setup-turn'); row.append(ctx.field(`Setup turn ${index + 1}`, turn.prompt, value => turn.prompt = value, true, 'compact-editor'), ctx.button('Remove turn', () => { config.setupTurns.splice(index,1); ctx.changed(); ctx.renderMain(); }, 'quiet danger')); contents.append(row);
  });
  contents.append(ctx.button('+ Add setup turn', () => { config.setupTurns.push({ id: crypto.randomUUID(), prompt: '' }); ctx.changed(); ctx.renderMain(); }, 'quiet', config.setupTurns.length >= 12));
  const policies = [['keepAll','Keep all history'],['resetBeforeFinal','Reset before final prompt'],['retainRecentCompleteTurns','Keep recent complete turns']];
  contents.append(appSelect(ctx,'Session history',config,'historyPolicy',policies,ctx.renderMain));
  if (config.historyPolicy === 'retainRecentCompleteTurns') contents.append(appNumber(ctx,'Retained turns',config,'retainedTurnCount',1,12));
  contents.append(ctx.field('Restored transcript JSON', config.restoredTranscriptJSON || '', value => { if (value.trim()) config.restoredTranscriptJSON = value; else delete config.restoredTranscriptJSON; }, true, 'compact-editor'));
  const projection = config.modelHistoryProjection ||= { policy: 'keepAll', retainedTurnCount: 2 };
  contents.append(appSelect(ctx,'Model-facing history',projection,'policy',[['keepAll','Keep all history'],['reset','Hide previous turns from the model'],['retainRecentCompleteTurns','Keep recent complete turns']],ctx.renderMain));
  if (projection.policy === 'retainRecentCompleteTurns') contents.append(appNumber(ctx,'Model-facing retained turns',projection,'retainedTurnCount',1,12));
  return appDisclosure(ctx, 'Conversation setup', `${config.setupTurns.length} setup turns and ${policies.find(([value]) => value === config.historyPolicy)?.[1] || 'Keep all history'}`, contents, `conversation-${test.id}`);
}
export function renderNativeCases(ctx) {
  const { state, node, button } = ctx, draft = state.draft;
  const visible = draft.cases.filter((item,index) => `${item.name || ctx.caseTitle(item,index)} ${item.prompt}`.toLowerCase().includes(state.caseSearch.toLowerCase()));
  let test = visible.find(item => item.id === state.caseId) || visible[0]; if (test) state.caseId = test.id;
  const layout = node('div', null, 'case-layout'), master = node('section', null, 'surface case-master'); master.append(ctx.panelHeader('Cases', draft.cases.length));
  const search = node('input'); search.type = 'search'; search.placeholder = 'Find a case'; search.setAttribute('aria-label', 'Find a case'); search.value = state.caseSearch;
  search.oninput = () => { state.caseSearch = search.value; const position = search.selectionStart; ctx.renderMain(); const replacement = document.querySelector('[aria-label="Find a case"]'); replacement?.focus(); if (position != null) replacement?.setSelectionRange(position,position); };
  const searchWrap = node('div', null, 'panel-search'); searchWrap.append(search); master.append(searchWrap);
  const list = node('div',null,'case-list');
  for (const item of visible) {
    const row = button('', () => { state.caseId = item.id; ctx.renderMain(); }, 'case-row'); row.setAttribute('aria-pressed',String(item.id === state.caseId));
    row.append(node('strong', item.name || ctx.caseTitle(item,draft.cases.indexOf(item))), node('span',item.prompt || 'Add a prompt')); list.append(row);
  }
  if (!visible.length) list.append(node('p','No matching cases','hint padded')); master.append(list);
  const masterActions = node('div',null,'case-master-actions'); masterActions.append(button('+ Add Case', () => { const item = { id: crypto.randomUUID(), name: 'New case', prompt: '', expected: '', scoring:'none' }; draft.cases.push(item); state.caseId = item.id; state.caseSearch = ''; ctx.changed(); ctx.renderMain(); }, 'quiet',draft.cases.length >= 100), button('Import Cases',ctx.importCases,'icon-button')); master.append(masterActions); layout.append(master);
  if (!test) { layout.append(ctx.empty('Select a test case','Choose a case to edit its prompt and expected response.')); return layout; }
  const editor = node('section',null,'surface case-editor'), header = node('div',null,'case-editor-heading'), title = node('input'); title.className = 'case-name-input'; title.value = test.name || ctx.caseTitle(test,draft.cases.indexOf(test)); title.setAttribute('aria-label','Case name'); title.oninput = () => { test.name = title.value; ctx.changed(); const selected = list.querySelector('[aria-pressed="true"] strong'); if (selected) selected.textContent = title.value || 'Untitled case'; };
  const menu = node('details',null,'action-menu'); const summary=node('summary');summary.setAttribute('aria-label','Case actions');summary.append(ctx.icon('more'));menu.append(summary); const choices = node('div',null,'menu-items'); choices.append(button('Duplicate Case', () => { const copy = structuredClone(test); copy.id = crypto.randomUUID(); copy.name = `${copy.name || 'Case'} copy`; draft.cases.splice(draft.cases.indexOf(test)+1,0,copy); state.caseId=copy.id; ctx.changed(); ctx.renderMain(); },'quiet',draft.cases.length >= 100),button('Delete Case', () => { draft.cases.splice(draft.cases.indexOf(test),1); state.caseId=draft.cases[0]?.id; ctx.changed(); ctx.renderMain(); },'quiet danger',draft.cases.length === 1)); menu.append(choices); header.append(title,menu); editor.append(header);
  const content = node('div',null,'editor-layout'),fields=node('div',null,'document-fields'),inspector=node('section',null,'case-inspector');inspector.setAttribute('aria-label','Case inspector');inspector.append(node('h2','Case inspector','inspector-title'));fields.append(ctx.field('Prompt',test.prompt,value => { test.prompt=value; const copy=list.querySelector('[aria-pressed="true"] span'); if (copy) copy.textContent=value || 'Add a prompt'; },true,'prompt-field'));
  const writing = node('div',null,'menu-items');
  for (const [id,label] of [['rewrite','Rewrite'],['grammar','Grammar'],['shorten','Shorten'],['tone','Change tone'],['prompt','Custom request']]) writing.append(button(label,()=>ctx.rewritePrompt(test,id),'secondary',!test.prompt.trim() || ctx.active()));
  const writingMenu=node('details',null,'action-menu writing-menu'),writingSummary=node('summary','Writing Tools');writingSummary.setAttribute('aria-label','Writing Tools');writingMenu.append(writingSummary,writing);const editorActions=node('div',null,'editor-actions');editorActions.append(writingMenu);fields.append(editorActions);
  const rubric = draft.scoringMode === 'modelJudge'; fields.append(ctx.field(rubric ? 'Reference answer (recommended for factual tasks)' : 'Expected response',test.expected || '',value => test.expected=value,true,'expected-field'));
  if (rubric) fields.append(node('p','Give the judge a known-good answer when correctness can be verified. Use Exact text scoring for deterministic equality checks. The AI rubric checks every requirement, including when the response matches this reference.','hint'));
  if (!draft.scoringMode) fields.append(appSelect(ctx,'Scoring',test,'scoring',[['exact','Exact match'],['contains','Contains'],['none','Trace only']]));
  inspector.append(appFieldChecks(ctx,test),appConversation(ctx,test));content.append(fields,inspector);editor.append(content); layout.append(editor); return layout;
}
