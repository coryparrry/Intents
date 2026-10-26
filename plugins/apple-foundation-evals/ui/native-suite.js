import { normalizeSchemaType, normalizeSchemaOptional, newSchemaField } from './suite-form-state.js';
// The case editor follows SuiteCasesView and ConversationConfigurationEditor.
export const APP_SCORING = { modelJudge: 'AI rubric', exactMatch: 'Exact text', containsExpected: 'Contains text', review: 'Collect only' };
/** Creates an application-format suite with model, rubric and example-case defaults for the given project. */
export function newAppSuite(projectId) {
  return { id: crypto.randomUUID(), projectId, name: 'My Foundation Model Eval', version: 'v1', instructions: 'Answer accurately and concisely.',
    criteria: 'The response is factually correct or consistent with the supplied reference answer.\nThe response directly answers the prompt without irrelevant material.\nThe response follows every requested format, tone, and length constraint.',
    scoringMode: 'modelJudge', repetitions: 1, temperature: .7, maxTokens: 1024, modelConfiguration: { provider: 'onDevice', samplingMode: 'automatic', temperatureEnabled: false, temperature: .7, seedEnabled: false, seed: 42, topK: 40, probabilityThreshold: .9, maximumResponseTokens: 1024, maximumToolCalls: 2, referenceMode: 'inline', contextPolicy: 'fitReferences', reasoningLevel: 'automatic', customization: { saveFullTranscript: true } },
    features: { tools: [], outputFields: [], outputSchemaDefinitions: [], profile: { enabled: false }, prewarm: false, streamResponse: false }, attachments: [],
    cases: [{ id: crypto.randomUUID(), name: 'Example', prompt: 'Explain why the sky appears blue in two sentences.', expected: '', scoring: 'none', conversation: { setupTurns: [], historyPolicy: 'keepAll', retainedTurnCount: 2 }, fieldAssertions: [] }] };
}
/** Builds a bound select that marks actual value changes and optionally refreshes dependent controls. */
export function appSelect(ctx, label, object, key, options, onChange) {
  const wrap = ctx.node('label', label, 'form-control'), input = ctx.node('select'); input.setAttribute('aria-label', label);
  for (const [value, title] of options) input.append(new Option(title, value));
  input.value = object[key] ?? options[0]?.[0];
  /** Writes a changed selection to its model property before notifying save and dependent-control callbacks. */
  input.onchange = () => { if (object[key] === input.value) return; object[key] = input.value; ctx.changed(); if (onChange) onChange(); };
  wrap.append(input); return wrap;
}
/** Builds a bound checkbox that marks actual boolean changes and optionally refreshes dependent controls. */
export function appToggle(ctx, label, object, key, onChange) {
  const wrap = ctx.node('label', null, 'toggle-control'), input = ctx.node('input'); input.type = 'checkbox'; input.checked = !!object[key];
  /** Writes a changed checkbox value before notifying save and dependent-control callbacks. */
  input.onchange = () => { if (!!object[key] === input.checked) return; object[key] = input.checked; ctx.changed(); if (onChange) onChange(); }; wrap.append(input, ctx.node('span', label)); return wrap;
}
/**
 * Builds a numeric field that commits only finite, in-range values and whole numbers when step is one.
 * For optional fields, clearing the input removes the property instead of assigning zero.
 */
export function appNumber(ctx, label, object, key, min, max, step = 1, optional = false) {
  const wrap = ctx.node('label', label, 'form-control'), input = ctx.node('input'); input.type = 'number'; input.min = min; input.max = max; input.step = step; input.value = object[key] ?? ''; input.setAttribute('aria-label', label);
  /** Validates numeric input, reports accessibility state and commits valid values or optional-property removal. */
  input.oninput = () => {
    const value = Number(input.value);
    const valid = optional && input.value === '' || input.value !== '' && Number.isFinite(value) && value >= min && value <= max && (step !== 1 || Number.isInteger(value));
    input.setCustomValidity?.(valid ? '' : `Enter a value between ${min} and ${max}.`);
    input.setAttribute('aria-invalid', String(!valid));
    if (!valid) return;
    if (optional && input.value === '') delete object[key]; else object[key] = value;
    ctx.changed();
  };
  /** Requests the browser validation message when the numeric field change is committed. */
  input.onchange = () => input.reportValidity?.();
  wrap.append(input); return wrap;
}
/** Builds an expandable section whose open state persists under the supplied disclosure key. */
export function appDisclosure(ctx, title, detail, content, key) {
  const wrap = ctx.node('details', null, 'optional-section'); wrap.open = !!ctx.state.disclosures?.[key];
  const summary = ctx.node('summary'), text = ctx.node('span'); text.append(ctx.node('strong', title), ctx.node('small', detail)); summary.append(ctx.icon('chevron'), text); wrap.append(summary, content);
  /** Stores this disclosure open state so rebuilding the view preserves the user selection. */
  wrap.ontoggle = () => { (ctx.state.disclosures ||= {})[key] = wrap.open; }; return wrap;
}
/** Builds a titled setup section with an icon, optional detail and supplied content nodes. */
export function appSection(ctx, title, detail, contents, symbol = 'file') {
  const section = ctx.node('section', null, 'surface setup-section'), header = ctx.node('div', null, 'section-heading'), text = ctx.node('div');
  text.append(ctx.node('h2', title)); if (detail) text.append(ctx.node('p', detail)); header.append(ctx.icon(symbol), text); section.append(header);
  const content = ctx.node('div', null, 'section-body'); content.append(...contents); section.append(content); return section;
}
/** Builds schema controls recursively through depth four and limits additions in each field list to eight. */
export function appSchemaEditor(ctx, fields, label = 'Fields', depth = 0) {
  const list = ctx.node('div', null, 'schema-editor');
  for (const item of fields) {
    item.children ||= []; item.enumValues ||= []; item.constraints ||= { stringPattern: '' };
    const card = ctx.node('div', null, 'schema-field'), header = ctx.node('div', null, 'form-grid');
    header.append(ctx.field('Field name', item.name, value => item.name = value), appSelect(ctx, 'Type', item, 'type', [['string','Text'],['integer','Integer'],['number','Number'],['boolean','True or false'],['enumeration','Choice'],['object','Object'],['array','Array'],['null','Null'],['union','One of'],['reference','Reference'],['imageReference','Image reference']], () => { normalizeSchemaType(item); ctx.renderMain(); }));
    card.append(header, ctx.field('Description', item.description, value => item.description = value), appToggle(ctx, 'Optional', item, 'isOptional', () => { normalizeSchemaOptional(item); ctx.renderMain(); }));
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
  list.append(ctx.button(`+ Add ${label === 'Element type' ? 'element type' : label === 'Definitions' ? 'definition' : 'field'}`, () => { fields.push(newSchemaField()); ctx.changed(); ctx.renderMain(); }, 'quiet', fields.length >= 8)); return list;
}
