import { appSuite, isAppSuite, validateAppEvidence, applyAssessment, sampleEnvelope } from './app-format.mjs';
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export const MAX_REQUEST_BYTES = 65 * 1024 * 1024;
export const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
// The complete portable definition and embedded reference files share the same
// byte ceiling; JSON-RPC string escaping still fits the 65 MiB request frame.
export const MAX_SUITE_BUNDLE_BYTES = MAX_OUTPUT_BYTES;
export const MAX_NATIVE_OUTPUT_BYTES = 16 * 1024 * 1024;

/** Requires a non-null, non-array object and returns it for continued validation. */
export function object(value, name = 'arguments') {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${name} must be an object`);
  return value;
}
/** Rejects non-object inputs and any own enumerable key outside the permitted list. */
export function only(value, keys) {
  object(value);
  for (const key of Object.keys(value)) if (!keys.includes(key)) throw new Error(`Unknown field: ${key}`);
}
/** Requires a UUID string and returns its lowercase form for storage and association checks. */
export function id(value, name = 'id') {
  if (typeof value !== 'string' || !UUID.test(value)) throw new Error(`${name} must be a UUID`);
  return value.toLowerCase();
}
/** Requires a string within the character bound, optionally rejecting blank text. */
function string(value, name, max, empty = true) {
  if (typeof value !== 'string' || value.length > max || (!empty && !value.trim())) throw new Error(`${name} must be ${empty ? 'a' : 'a non-empty'} string of at most ${max} characters`);
  return value;
}
/** Applies a nullish fallback and validates a finite inclusive numeric range, optionally requiring an integer. */
function number(value, fallback, min, max, name, integer = false) {
  value ??= fallback;
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) throw new Error(`${name} must be ${integer ? 'an integer' : 'a number'} from ${min} to ${max}`);
  return value;
}
/** Normalizes app or legacy suites, enforcing case identity, size, repetition, and output-budget constraints before execution or persistence. */
export function suite(value, generateId, options = {}) {
  object(value, 'suite');
  if (Array.isArray(value.cases) && value.cases.some((item) => item && (item.documentEvidence != null || item.criteriaOverride != null || item.prompt?.format === 'document-case-v1'))) {
    throw new Error('Document suites are supported in the native Intents app. This plugin cannot discard their source evidence or case-specific scoring.');
  }
  if (isAppSuite(value)) return appSuite(value, generateId, options);
  only(value, ['id', 'name', 'instructions', 'cases', 'repetitions', 'temperature', 'maxTokens', 'projectId', 'revision', 'updatedAt']);
  if (!Array.isArray(value.cases) || value.cases.length < 1 || value.cases.length > 100) throw new Error('cases must contain 1 to 100 entries');
  const ids = new Set();
  const cases = value.cases.map((item) => {
    only(item, ['id', 'name', 'prompt', 'expected', 'scoring']);
    const caseId = string(item.id, 'case id', 128, false);
    if (Buffer.byteLength(caseId) > 256) throw new Error('Case id must not exceed 256 UTF-8 bytes');
    if (ids.has(caseId)) throw new Error('case ids must be unique');
    ids.add(caseId);
    if (!['exact', 'contains', 'none'].includes(item.scoring)) throw new Error('scoring must be exact, contains, or none');
    if (item.scoring !== 'none' && (typeof item.expected !== 'string' || !item.expected.length)) throw new Error('scored cases require non-empty expected text');
    return { id: caseId, ...(item.name === undefined ? {} : { name: string(item.name, 'case name', 160) }), prompt: string(item.prompt, 'prompt', 8192, false), ...(item.expected === undefined ? {} : { expected: string(item.expected, 'expected', 8192) }), scoring: item.scoring };
  });
  const result = { id: value.id === undefined ? generateId() : id(value.id), name: string(value.name, 'name', 160, false), instructions: string(value.instructions ?? '', 'instructions', 16384), cases, repetitions: number(value.repetitions, 1, 1, 10, 'repetitions', true), temperature: number(value.temperature, 0, 0, 2, 'temperature'), maxTokens: number(value.maxTokens, 256, 1, 4096, 'maxTokens', true) };
  if (cases.length * result.repetitions > 100) throw new Error('A suite can have at most 100 total case repetitions');
  if (cases.length * result.repetitions * result.maxTokens > 65536) throw new Error('Total output token budget must not exceed 65536');
  if (Buffer.byteLength(result.instructions) > 16384) throw new Error('Instructions must not exceed 16384 UTF-8 bytes');
  if (cases.reduce((total, item) => total + Buffer.byteLength(result.instructions) + Buffer.byteLength(item.prompt), 0) * result.repetitions > 524288) throw new Error('Expanded instructions and prompts must not exceed 524288 UTF-8 bytes');
  if (Buffer.byteLength(JSON.stringify(result)) > 1024 * 1024) throw new Error('Suite exceeds the 1 MiB limit');
  for (const key of ['projectId', 'revision', 'updatedAt']) if (value[key] !== undefined) result[key] = key === 'projectId' ? id(value[key], key) : string(value[key], key, 64);
  return result;
}
/** Validates result identity, completeness, timing, scores, trace bounds, and raw app evidence against the saved suite; optional assessment projection validates reassessed envelopes. */
export function nativeResult(value, savedSuite, { allowAssessmentProjection = false } = {}) {
  object(value, 'native result');
  if (value.model !== undefined) string(value.model, 'model', 256);
  if (!['completed', 'failed', ...(isAppSuite(savedSuite) ? ['cancelled'] : [])].includes(value.status)) throw new Error('Native worker returned an invalid status');
  if (!Array.isArray(value.results) || value.results.length > savedSuite.cases.length * savedSuite.repetitions) throw new Error('Native worker returned invalid results');
  const appFormat = isAppSuite(savedSuite);
  const seen = new Set();
  for (const result of value.results) {
    object(result, 'case result');
    if (appFormat && typeof result.caseId === 'string') result.caseId = result.caseId.toLowerCase();
    const source = savedSuite.cases.find((item) => item.id === result.caseId);
    if (!source || !Number.isInteger(result.repetition) || result.repetition < 1 || result.repetition > savedSuite.repetitions) throw new Error('Native worker returned an unknown case or repetition');
    const key = `${result.caseId}\0${result.repetition}`;
    if (seen.has(key)) throw new Error('Native worker returned duplicate results');
    seen.add(key);
    string(result.response, 'response', 65536);
    if (result.prompt !== source.prompt || result.expected !== source.expected) throw new Error('Native result does not match its saved case');
    if (result.passed !== null && typeof result.passed !== 'boolean') throw new Error('Native worker returned an invalid score');
    if (result.score !== null && (!Number.isFinite(result.score) || result.score < 0 || result.score > (appFormat ? 4 : 1))) throw new Error('Native worker returned an invalid score');
    if (appFormat) { result.scoreScale = 'appRubric'; result.caseName = source.name; }
    number(result.durationMs, undefined, 0, 1800000, 'durationMs');
    if (!result.trace || !Array.isArray(result.trace.transcript) || result.trace.transcript.length > (appFormat ? 2048 : 128)) throw new Error('Native worker returned an invalid trace');
  }
  if (value.status === 'completed' && value.results.length !== savedSuite.cases.length * savedSuite.repetitions) throw new Error('Native worker completed without all case results');
  if (value.appRun) {
    object(value.appRun, 'appRun');
    validateAppEvidence(value.appRun);
    if (id(value.appRun.suiteID, 'app run suiteID') !== savedSuite.id) throw new Error('App run suite identity does not match its saved suite');
    if (!Array.isArray(value.appRun.results) || value.appRun.results.length !== value.results.length) throw new Error('App run sample evidence does not match its result envelope');
    for (const sample of value.appRun.results) {
      const result = value.results.find((item) => item.caseId.toLowerCase() === sample.caseID?.toLowerCase() && item.repetition === sample.repetition);
      const expected = allowAssessmentProjection ? applyAssessment(value.appRun, [sampleEnvelope(sample)])[0] : sampleEnvelope(sample);
      if (result && (result.score !== expected.score || result.passed !== expected.passed)) throw new Error('App sample score/status does not match its evidence');
      if (!result || sample.prompt !== result.prompt || sample.expected !== result.expected || sample.response !== result.response || sample.durationMilliseconds !== result.durationMs) throw new Error('App sample evidence does not match its result envelope');
    }
  }
  return value;
}
