export const UI_URI = 'ui://apple-foundation-evals/workspace';
export const UI_MIME = 'text/html;profile=mcp-app';
export const UI_META = { ui: { csp: { connectDomains: [], resourceDomains: [] } }, 'openai/ui': { preferredDisplayMode: 'fullscreen', availableDisplayModes: ['inline', 'fullscreen'] } };
import { SUITE_SCHEMA, DRAFT_SUITE_SCHEMA, FIELD_SCHEMA, text, obj, uuid, draftSchema } from './app-schema.mjs';
import { WORKFLOW_TOOLS } from './workflow-tools.mjs';
export { SUITE_SCHEMA };
const referenceFiles = { type: 'array', maxItems: 20, items: obj({ attachmentId: uuid, name: text(1024, 1), mimeType: text(128, 1), base64: text(13333336, 1) }, ['name', 'mimeType', 'base64']) };
const icon = { src: 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.33"><path d="M4 3h12v14H4zM7 7h6M7 10h6M7 13h3"/></svg>'), mimeType: 'image/svg+xml' };
const define = (name, title, description, inputSchema, readOnly = true, destructive = false, meta) => ({ name, title, description, inputSchema: { ...inputSchema, $defs: { field: draftSchema(FIELD_SCHEMA) } }, annotations: { readOnlyHint: readOnly, destructiveHint: destructive, idempotentHint: readOnly || destructive, openWorldHint: false }, ...(meta ? { _meta: meta, icons: [icon] } : {}) });
export const TOOLS = [
  define('eval_open_workspace', 'Evaluation Workspace', 'Open local suites and real on-device Foundation Models evaluation runs. Availability is checked only when requested.', obj(), true, false, { ui: { resourceUri: UI_URI }, 'openai/ui': { entrypoints: [{ type: 'global' }, { type: 'thread' }] } }),
  define('eval_open_trace', 'Evaluation Trace', 'Open an exported .afevaltrace file in the evaluation workspace.', obj({ file: obj({ name: text(1024, 1), resourceUri: text(4096, 1) }, ['name', 'resourceUri']) }, ['file']), true, false, { ui: { resourceUri: UI_URI }, 'openai/ui': { entrypoints: [{ type: 'file', extensions: ['.afevaltrace'] }] } }),
  define('eval_model_status', 'Check on-device model', 'Check the local Apple Foundation Models system model. May compile the bundled native runner on first use; no remote provider is used.', obj()),
  define('eval_list_suites', 'List evaluation suites', 'List saved local evaluation suites.', obj({ projectId: uuid })),
  define('eval_save_suite', 'Save evaluation suite', 'Validate and save a local suite. Omit its id to create a new suite.', obj({ suite: DRAFT_SUITE_SCHEMA, projectId: uuid, expectedRevision: text(64) }, ['suite']), false),
  define('eval_delete_suite', 'Delete evaluation suite', 'Delete a saved suite; existing runs retain their suite snapshot.', obj({ suiteId: uuid }, ['suiteId']), false, true),
  define('eval_start_run', 'Run on-device evaluation', 'Start one real on-device evaluation. Only one run can be active at a time.', obj({ suiteId: uuid, expectedRevision: text(64) }, ['suiteId']), false),
  define('eval_list_runs', 'List evaluation runs', 'List summaries of saved real evaluation runs.', obj({ projectId: uuid })),
  define('eval_get_run', 'Read evaluation trace', 'Read a saved run with responses, scores, timing, and model traces.', obj({ runId: uuid }, ['runId'])),
  define('eval_cancel_run', 'Cancel evaluation run', 'Cancel an active local evaluation and persist its cancelled state.', obj({ runId: uuid }, ['runId']), false),
  define('eval_delete_run', 'Delete evaluation run', 'Delete a completed, cancelled, or failed local evaluation.', obj({ runId: uuid }, ['runId']), false, true),
  define('eval_compare_runs', 'Compare evaluation runs', 'Compare case responses, scores, and timings from two to four saved runs.', obj({ runIds: { type: 'array', minItems: 2, maxItems: 4, uniqueItems: true, items: uuid } }, ['runIds'])),
  define('eval_preview_response', 'Preview model response', 'Generate one real local response with the current settings without saving evaluation history.', obj({ suite: DRAFT_SUITE_SCHEMA, prompt: text(32000, 1), previewId: uuid }, ['suite', 'prompt']), false),
  define('eval_preview_status', 'Preview generation status', 'Read only the current preview and its actual native live response, when streaming is enabled.', obj({}, [])),
  define('eval_cancel_preview', 'Cancel preview generation', 'Cancel only the matching active or queued response preview; active cancellation waits for its guarded worker lease to be released.', obj({ previewId: uuid }, []), false),
  define('eval_list_projects', 'List projects', 'List local projects and their suite/run ownership.', obj()),
  define('eval_create_project', 'Create project', 'Create a local evaluation project.', obj({ name: text(160, 1), description: text(4096) }, ['name']), false),
  define('eval_update_project', 'Update project', 'Rename or describe a local project.', obj({ projectId: uuid, name: text(160, 1), description: text(4096) }, ['projectId']), false),
  define('eval_project_overview', 'Project overview', 'Summarize current and stale suite evidence for a project.', obj({ projectId: uuid }, ['projectId'])),
  define('eval_import_suite', 'Import suite', 'Import an app-format or flat suite, preserving identities, settings and portable embedded text references. Spotlight search authorization is reset; enable it locally after import.', obj({ suite: DRAFT_SUITE_SCHEMA, json: text(16777216), referenceFiles, projectId: uuid, expectedRevision: text(64) }), false),
  define('eval_export_suite', 'Export suite', 'Export the portable suite definition using application field names.', obj({ suiteId: uuid }, ['suiteId'])),
  define('eval_import_cases', 'Import cases', 'Append named cases from JSON, JSONL or CSV using the app case importer fields.', obj({ suiteId: uuid, format: { type: 'string', enum: ['json', 'jsonl', 'csv'] }, text: text(5000000), mapping: obj({ nameColumn: text(256), promptColumn: text(256, 1), expectedColumn: text(256) }, ['promptColumn']), expectedRevision: text(64) }, ['suiteId', 'format', 'text']), false),
  define('eval_add_reference_text', 'Add reference text', 'Attach a portable UTF-8 text reference with verified size and SHA-256 integrity.', obj({ suiteId: uuid, name: text(1024, 1), text: text(524288), expectedRevision: text(64) }, ['suiteId', 'name', 'text']), false),
  define('eval_add_reference_file', 'Add reference file', 'Import a PDF, UTF-8 text or image file within the app limits (5 MB text/PDF, 10 MB images) with actual native extraction and private integrity-checked bytes.', obj({ suiteId: uuid, name: text(1024, 1), mimeType: text(128, 1), base64: text(13333336, 1), expectedRevision: text(64) }, ['suiteId', 'name', 'mimeType', 'base64']), false),
  define('eval_import_run', 'Import run', 'Import a real app evaluation run or plugin trace preserving full sample and assessment evidence.', obj({ run: { type: 'object' }, json: text(33554432), projectId: uuid, suiteId: uuid }), false),
  define('eval_parse_trace', 'Read imported trace', 'Validate and open raw app or plugin trace evidence without writing local suites, runs, references, or projects.', obj({ json: text(33554432, 1) }, ['json'])),
  define('eval_export_run', 'Export run', 'Export raw application evidence when present, otherwise the plugin trace.', obj({ runId: uuid }, ['runId'])),
  define('eval_analyze_cases', 'Analyze case evidence', 'Read real subject, conversation, tool, workflow, judge, timing and assertion evidence by case.', obj({ runId: uuid, caseIds: { type: 'array', items: text(128, 1), maxItems: 100, uniqueItems: true } }, ['runId'])),

  ...WORKFLOW_TOOLS,
];
export const SERVER_INFO = { name: 'apple-foundation-evals', title: 'Apple Foundation Evals', version: '0.5.0', icons: [icon] };
export const CAPABILITIES = { tools: {}, resources: {} };
