import { createHash, randomUUID } from 'node:crypto';
import { SPOTLIGHT_DEFAULTS, PROFILE_DEFAULTS } from './app-defaults.mjs';
import { APP_SUITE_SCHEMA, DRAFT_APP_SUITE_SCHEMA, validateSchema } from './app-schema.mjs';
export const isAppSuite = (value) => ['version', 'criteria', 'scoringMode', 'modelConfiguration', 'features', 'attachments', 'judgeConfiguration', 'releasePolicy'].some((key) => value[key] !== undefined) || value.cases?.some((item) => item.conversation !== undefined || item.fieldAssertions !== undefined);
const clean = (value) => Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined && item !== null));
export const MODEL_DEFAULTS = { provider: 'onDevice', reasoningLevel: 'automatic', samplingMode: 'automatic', temperatureEnabled: false, temperature: 0.7, seedEnabled: false, seed: 42, topK: 40, probabilityThreshold: 0.9, maximumResponseTokens: 1024, referenceMode: 'inline', contextPolicy: 'fitReferences', maximumToolCalls: 2 };
function identifier(value, label) { if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) throw new Error(`${label} must be an identifier`); }
function fields(items = [], generateId = randomUUID) {
  return (items || []).map((value) => ({ id: generateId(), description: '', isOptional: false, enumValues: [], constraints: { stringPattern: '' }, referenceName: '', representNilExplicitlyInGeneratedContent: false, ...clean(value), constraints: { stringPattern: '', ...clean(value.constraints || {}) }, children: fields(value.children, generateId), enumValues: (value.enumValues || []).map((item) => ({ id: generateId(), ...item })) }));
}
function schemaCheck(items, definitions = []) {
  const ids = new Set(); let count = 0;
  const names = new Set(definitions.map((item) => item.name));
  if (names.size !== definitions.length) throw new Error('Schema definition names must be unique');
  const refs = new Map();
  const visit = (list, depth = 1, optional = true, definitionName = null) => {
    const siblingNames = new Set();
    for (const field of list) {
      if (++count > 32 || depth > 4) throw new Error('Schema exceeds 32 nodes or four levels');
      identifier(field.name, 'Schema field name');
      if (ids.has(field.id) || siblingNames.has(field.name)) throw new Error('Schema field IDs and sibling names must be unique');
      ids.add(field.id); siblingNames.add(field.name);
      if (field.isOptional && !optional) throw new Error('Only object properties can be optional');
      if (field.children.length && !['object', 'array', 'union'].includes(field.type)) throw new Error('Only object, array and union fields can have children');
      if (field.type === 'array' && field.children.length !== 1) throw new Error('Array fields require one element schema');
      if (field.type === 'union' && field.children.length < 2) throw new Error('Union fields require at least two variants');
      if (field.type === 'enumeration' && (!field.enumValues.length || new Set(field.enumValues.map((item) => item.value)).size !== field.enumValues.length)) throw new Error('Enumeration fields require unique values');
      if (field.type === 'reference') {
        if (!names.has(field.referenceName)) throw new Error('Schema reference is undefined');
        if (definitionName) refs.set(definitionName, [...(refs.get(definitionName) || []), field.referenceName]);
      }
      visit(field.children, depth + 1, field.type === 'object', definitionName);
    }
  };
  visit(items); for (const item of definitions) visit([item], 1, false, item.name);
  const active = new Set(); const visited = new Set();
  const cycle = (name) => { if (active.has(name)) throw new Error('Schema references contain a cycle'); if (visited.has(name)) return; active.add(name); for (const ref of refs.get(name) || []) cycle(ref); active.delete(name); visited.add(name); };
  for (const name of names) cycle(name);
}
function withDefaults(defaults, value) {
  const result = structuredClone(defaults);
  for (const [key, item] of Object.entries(clean(value || {}))) result[key] = item && typeof item === 'object' && !Array.isArray(item) && result[key] && typeof result[key] === 'object' && !Array.isArray(result[key]) ? withDefaults(result[key], item) : item;
  return result;
}
export function appSuite(value, generateId = randomUUID, { draft = false } = {}) {
  const schema = draft ? DRAFT_APP_SUITE_SCHEMA : APP_SUITE_SCHEMA;
  validateSchema(value, schema, 'suite', schema);
  const modelConfiguration = { ...MODEL_DEFAULTS, ...clean(value.modelConfiguration || {}) };
  if (modelConfiguration.customization?.visionTools) modelConfiguration.customization.visionTools = { ocrEnabled: false, barcodeEnabled: false, ...clean(modelConfiguration.customization.visionTools) };
  if (modelConfiguration.customization) modelConfiguration.customization = { useCase: 'general', guardrails: 'standard', schemaPrompt: 'included', toolCalling: 'automatic', ...clean(modelConfiguration.customization) };
  const sourceFeatures = value.features || {};
  const features = { tools: [], profile: {}, outputFields: [], outputSchemaDefinitions: [], outputRepresentNilExplicitlyInGeneratedContent: false, prewarm: false, streamResponse: false, ...clean(sourceFeatures) };
  features.profile = withDefaults(PROFILE_DEFAULTS, features.profile);
  features.spotlightSearch = withDefaults(SPOTLIGHT_DEFAULTS, features.spotlightSearch);
  if (modelConfiguration.temperatureEnabled && modelConfiguration.temperature > 1) throw new Error('temperature must be between 0 and 1 when enabled');
  if (modelConfiguration.samplingMode === 'probability' && modelConfiguration.probabilityThreshold < 0.01) throw new Error('probabilityThreshold must be between 0.01 and 1 when selected');
  const profile = features.profile;
  if (profile.enabled) {
    if (profile.afterToolTemperatureEnabled && profile.afterToolTemperature > 1) throw new Error('afterToolTemperature must be between 0 and 1 when enabled');
    if (profile.afterToolSamplingMode === 'probability' && profile.afterToolProbabilityThreshold < 0.01) throw new Error('afterToolProbabilityThreshold must be between 0.01 and 1 when selected');
    if (profile.afterToolMaximumResponseTokens != null && profile.afterToolMaximumResponseTokens < 128) throw new Error('afterToolMaximumResponseTokens must be between 128 and 4096 when the profile is enabled');
  }
  const vision = modelConfiguration.customization?.visionTools;
  const hasTools = modelConfiguration.referenceMode === 'lookupTool' || features.tools.length > 0 || features.spotlightSearch.enabled || vision?.ocrEnabled || vision?.barcodeEnabled;
  if (hasTools && (modelConfiguration.maximumToolCalls < 1 || modelConfiguration.maximumToolCalls > 4)) throw new Error('maximumToolCalls must be between 1 and 4 when tools are configured');
  features.outputFields = fields(features.outputFields, generateId); features.outputSchemaDefinitions = fields(features.outputSchemaDefinitions, generateId);
  if (!draft) schemaCheck(features.outputFields, features.outputSchemaDefinitions);
  const toolIds = new Set(); const toolNames = new Set();
  features.tools = features.tools.map((item) => {
    const result = { id: generateId(), description: '', parameters: [], schemaDefinitions: [], representNilExplicitlyInGeneratedContent: false, mode: 'fixture', fixtureResponse: '', endpoint: '', ...clean(item) };
    if (!draft) identifier(result.name, 'Tool name');
    if (toolIds.has(result.id) || (!draft && toolNames.has(result.name))) throw new Error('Tool IDs and names must be unique');
    toolIds.add(result.id); toolNames.add(result.name);
    result.parameters = fields(result.parameters, generateId); result.schemaDefinitions = fields(result.schemaDefinitions, generateId); if (!draft) schemaCheck(result.parameters, result.schemaDefinitions);
    if (!draft && result.mode === 'localHTTP') {
      let url; try { url = new URL(result.endpoint); } catch { throw new Error('Tool endpoint must be a local HTTP URL'); }
      if (url.protocol !== 'http:' || !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) || url.username || url.password || url.port === '17873') throw new Error('Tool endpoint must be loopback HTTP and cannot use the reserved MCP port');
    }
    if (Buffer.byteLength(result.fixtureResponse) > 4096) throw new Error('Fixture response exceeds 4096 UTF-8 bytes');
    return result;
  });
  if (!draft && toolNames.has('search_reference_files')) throw new Error('Custom tools must not use the reserved reference lookup name');
  const scoringMode = value.scoringMode || 'review';
  if (!draft && scoringMode === 'modelJudge' && !(value.criteria || '').trim()) throw new Error('AI rubric scoring requires criteria');
  const seen = new Set();
  const cases = value.cases.map((item, index) => {
    const caseId = (item.id || generateId()).toLowerCase();
    // Full app runs use Codable UUID cases; legacy IDs are supported only in flat suites.
    validateSchema(caseId, { type: 'string', format: 'uuid' }, 'case id');
    if (seen.has(caseId)) throw new Error('case ids must be unique'); seen.add(caseId);
    const conversation = { setupTurns: [], historyPolicy: 'keepAll', retainedTurnCount: 2, ...clean(item.conversation || {}) };
    if (conversation.modelHistoryProjection) conversation.modelHistoryProjection = { policy: 'keepAll', retainedTurnCount: 2, ...clean(conversation.modelHistoryProjection) };
    conversation.setupTurns = conversation.setupTurns.map((turn) => ({ id: generateId(), ...turn }));
    if (new Set(conversation.setupTurns.map((turn) => turn.id)).size !== conversation.setupTurns.length) throw new Error('Setup turn IDs must be unique');
    if (!draft && conversation.restoredTranscriptJSON?.trim()) { try { JSON.parse(conversation.restoredTranscriptJSON); } catch { throw new Error('Restored transcript must be valid JSON'); } }
    const result = { id: caseId, name: item.name ?? `Case ${index + 1}`, prompt: item.prompt, expected: item.expected || '', conversation, ...(item.fieldAssertions ? { fieldAssertions: item.fieldAssertions.map((entry) => ({ id: generateId(), expectedValue: '', ...entry })) } : {}) };
    if (!draft && ['exactMatch', 'containsExpected'].includes(scoringMode) && !result.expected.length) throw new Error('scored cases require non-empty expected text');
    const assertions = result.fieldAssertions || [];
    if (!draft && assertions.length > 32) throw new Error('Use at most 32 field assertions per case');
    if (!draft && new Set(assertions.map((entry) => entry.id?.toLowerCase())).size !== assertions.length) throw new Error('Assertion IDs must be unique');
    for (const assertion of draft ? [] : assertions) {
      if (typeof assertion.pointer !== 'string' || assertion.pointer && !assertion.pointer.startsWith('/') || /~(?![01])/.test(assertion.pointer)) throw new Error('Field assertion pointer must be a JSON pointer with valid escapes');
      if (assertion.operation === 'containsText' && !assertion.expectedValue.length) throw new Error('Text assertions require non-empty text');
      if (['equals', 'minimum', 'maximum'].includes(assertion.operation)) { let parsed; try { parsed = JSON.parse(assertion.expectedValue); } catch { throw new Error('Assertion expected value must be JSON'); } if (assertion.operation !== 'equals' && typeof parsed !== 'number') throw new Error('Numeric assertions require a number'); }
    }
    return result;
  });
  const attachments = (value.attachments || []).map((item) => {
    if (item.text !== undefined && item.text !== null && !item.storedFilename) {
      const bytes = Buffer.byteLength(item.text); const sha256 = createHash('sha256').update(item.text).digest('hex');
      if ((item.byteCount !== undefined && item.byteCount !== bytes) || (item.sha256 && item.sha256 !== sha256)) throw new Error('Reference attachment content does not match its integrity metadata');
      return { id: generateId(), ...clean(item), byteCount: bytes, sha256 };
    }
    if (!item.storedFilename || !item.sha256 || !Number.isInteger(item.byteCount)) throw new Error('File references require storedFilename, byteCount and SHA-256 metadata');
    return { id: generateId(), ...clean(item) };
  });
  if (!draft && modelConfiguration.referenceMode === 'lookupTool' && !attachments.some((item) => item.kind === 'text')) throw new Error('Reference lookup requires at least one text reference');
  if (attachments.filter((item) => item.kind === 'image').length > 4) throw new Error('A suite can have at most four image references');
  if (new Set(attachments.map((item) => item.id)).size !== attachments.length) throw new Error('Attachment IDs must be unique');
  const result = { id: value.id?.toLowerCase() || generateId(), name: value.name, version: value.version || 'v1', instructions: value.instructions ?? '', criteria: value.criteria ?? '', scoringMode, repetitions: value.repetitions ?? 1, modelConfiguration, features, cases, attachments, judgeConfiguration: { mode: 'sameModel', includeReferenceAttachments: true, ...clean(value.judgeConfiguration || {}) }, releasePolicy: { required: false, criticalCaseIDs: [], maximumErrorCount: 0, requireApprovedBaseline: false, maximumPassRateRegression: 0, ...clean(value.releasePolicy || {}) }, ...(value.projectId ? { projectId: value.projectId.toLowerCase() } : {}), ...(value.revision ? { revision: value.revision } : {}), ...(value.updatedAt ? { updatedAt: value.updatedAt } : {}) };
  result.temperature = modelConfiguration.temperatureEnabled ? modelConfiguration.temperature : 0;
  result.maxTokens = modelConfiguration.maximumResponseTokens;
  for (const item of result.cases) item.scoring = { review: 'none', exactMatch: 'exact', containsExpected: 'contains', modelJudge: 'none' }[scoringMode];
  if (cases.length * result.repetitions > 100) throw new Error('Suite exceeds case repetitions or output token budget');
  if (result.instructions.length > 32000) throw new Error('Instructions must not exceed 32000 characters');
  if (Buffer.byteLength(JSON.stringify(result)) > 1024 * 1024) throw new Error('Suite exceeds the 1 MiB limit');
  return result;
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
export function revision(suite) {
  const { revision: old, updatedAt, projectId, ...definition } = suite;
  return createHash('sha256').update(JSON.stringify(canonical(definition))).digest('hex');
}
export function portableSuite(suite) {
  const { projectId, revision: old, updatedAt, temperature, maxTokens, ...definition } = suite;
  if (!isAppSuite(suite)) return { ...definition, temperature, maxTokens };
  definition.cases = definition.cases.map(({ scoring, ...item }) => item);
  return definition;
}
export function parseImport(args, key) {
  if ((args[key] === undefined) === (args.json === undefined)) throw new Error(`Supply exactly one of ${key} or json`);
  if (args[key] !== undefined) return args[key];
  if (typeof args.json !== 'string' || Buffer.byteLength(args.json) > 32 * 1024 * 1024) throw new Error('Import exceeds size limit');
  try { return JSON.parse(args.json); } catch { throw new Error('Import must be valid JSON'); }
}
export function sampleEnvelope(sample, cases = []) {
  const transcript = sample.featureTrace?.transcript;
  let entries = [];
  if (transcript?.transcriptJSON) { try { const parsed = JSON.parse(Buffer.from(transcript.transcriptJSON, 'base64').toString('utf8')); entries = Array.isArray(parsed) ? parsed : Array.isArray(parsed.entries) ? parsed.entries : []; } catch { /* Keep the original capture, including any recorded omission. */ } }
  return { caseId: sample.caseID?.toLowerCase(), caseName: sample.caseName, repetition: sample.repetition, prompt: sample.prompt, expected: sample.expected, response: sample.response, passed: sample.status === 'passed' ? true : ['failed', 'error'].includes(sample.status) ? false : null, score: sample.score ?? null, scoreScale: 'appRubric', durationMs: sample.durationMilliseconds, appSample: sample, trace: { appSample: sample, transcript: entries, ...(transcript ? { appTranscript: transcript } : {}), ...(sample.workflowTrace ? { workflow: sample.workflowTrace } : {}), ...(sample.toolCalls ? { toolCalls: sample.toolCalls } : {}), ...(sample.judgeTrace ? { judge: sample.judgeTrace } : {}) }, ...(sample.errorMessage ? { error: sample.errorMessage } : {}) };
}

// Match the app's effectiveResults projection while keeping original subject/judge evidence.
export function applyAssessment(run, results) {
  if (!run) return results;
  const selected = run.selectedAssessmentID ? run.assessments?.find((item) => item.id?.toLowerCase() === run.selectedAssessmentID.toLowerCase()) : run.assessments?.at(-1);
  if (!selected && !run.selectedAssessmentID) return results;
  return results.map((result) => {
    const original = result.appSample || result.trace?.appSample || run.results.find((item) => item.caseID?.toLowerCase() === result.caseId.toLowerCase() && item.repetition === result.repetition);
    const sample = selected?.samples?.find((item) => item.sampleID?.toLowerCase() === original?.id?.toLowerCase());
    return { ...result, passed: sample?.status === 'passed' ? true : ['failed', 'error'].includes(sample?.status) ? false : null, score: sample?.score ?? null, scoreScale: 'appRubric', assessmentId: selected?.id || run.selectedAssessmentID, assessmentSample: sample || null, trace: { ...result.trace, ...(selected ? { assessment: selected } : {}), ...(sample?.trace ? { judge: sample.trace } : {}) } };
  });
}

// Flat envelopes use ISO strings. Native Codable traces may use seconds since
// 2001; normalize that explicitly rather than relying on Date.parse coercion.
export function importedTimestamp(value, { apple = false } = {}) {
  if (apple && typeof value === 'number' && Number.isFinite(value)) {
    const date = new Date((value + 978307200) * 1000);
    if (Number.isFinite(date.getTime())) return importedTimestamp(date.toISOString());
  }
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T(?:[01]\d|2[0-3]):[0-5]\d:[0-5]\d(?:\.\d{1,9})?(?:Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)$/.test(value)) throw new Error('Run import requires valid ISO timestamps');
  const time = Date.parse(value);
  const calendarDate = new Date(`${value.slice(0, 10)}T00:00:00.000Z`);
  if (!Number.isFinite(time) || !Number.isFinite(calendarDate.getTime()) || !calendarDate.toISOString().startsWith(value.slice(0, 10))) throw new Error('Run import requires valid ISO timestamps');
  return new Date(time).toISOString();
}

export function validateAppEvidence(run) {
  if (!run || typeof run !== 'object' || !Array.isArray(run.results)) throw new Error('App run requires sample evidence');
  const validId = (value, label) => { if (typeof value !== 'string') throw new Error(`${label} must be a UUID`); validateSchema(value, { type: 'string', format: 'uuid' }, label); return value.toLowerCase(); };
  const score = (sample) => { if (!['passed', 'failed', 'unscored', 'error'].includes(sample.status)) throw new Error('Invalid app evidence status'); if (sample.score != null && (!Number.isInteger(sample.score) || sample.score < 1 || sample.score > 4)) throw new Error('App rubric score must be an integer from 1 to 4 or null'); };
  const sampleIds = new Set(); const keys = new Set();
  for (const sample of run.results) {
    const sampleId = validId(sample.id, 'sample id'); const caseId = validId(sample.caseID, 'sample caseID'); score(sample);
    const key = `${caseId}\0${sample.repetition}`;
    if (sampleIds.has(sampleId) || keys.has(key)) throw new Error('App sample identities must be unique'); sampleIds.add(sampleId); keys.add(key);
  }
  if (run.assessments !== undefined && (!Array.isArray(run.assessments) || run.assessments.length > 1000)) throw new Error('Invalid assessment history');
  const assessmentIds = new Set();
  for (const assessment of run.assessments || []) {
    const assessmentId = validId(assessment.id, 'assessment id');
    if (assessmentIds.has(assessmentId)) throw new Error('Assessment IDs must be unique'); assessmentIds.add(assessmentId);
    if (assessment.runID && validId(assessment.runID, 'assessment runID') !== validId(run.id, 'run id')) throw new Error('Assessment belongs to another run');
    if (!Array.isArray(assessment.samples) || assessment.samples.length > run.results.length) throw new Error('Invalid assessment samples');
    const assessed = new Set();
    for (const sample of assessment.samples) {
      const sampleId = validId(sample.sampleID, 'assessed sampleID'); score(sample);
      if (!sampleIds.has(sampleId) || assessed.has(sampleId)) throw new Error('Assessment sample association is invalid'); assessed.add(sampleId);
    }
  }
  if (run.selectedAssessmentID) validId(run.selectedAssessmentID, 'selected assessment id');
  return run;
}
