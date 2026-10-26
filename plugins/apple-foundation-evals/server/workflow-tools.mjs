import { text, obj, uuid } from './app-schema.mjs';

const expectedRevision = text(64, 1);
/** Builds a workflow MCP tool with a closed argument schema and read-only or mutation annotations. */
const tool = (name, title, description, properties, required, readOnly = true) => ({ name, title, description, inputSchema: obj(properties, required), annotations: { readOnlyHint: readOnly, destructiveHint: false, idempotentHint: readOnly, openWorldHint: false } });
export const WORKFLOW_TOOLS = [
  tool('eval_create_experiment', 'Create instruction experiment', 'Freeze current and candidate instructions with the actual app scoring and case contracts.', { suiteId: uuid, name: text(160, 1), candidateInstructions: text(32000, 1), expectedRevision }, ['suiteId', 'name', 'candidateInstructions'], false),
  tool('eval_run_experiment', 'Run instruction experiment', 'Run both frozen variants in balanced order using the local on-device model.', { experimentId: uuid, expectedRevision }, ['experimentId'], false),
  tool('eval_cancel_experiment', 'Cancel instruction experiment', 'Stop the active local instruction experiment and release its guarded worker lease.', { experimentId: uuid }, ['experimentId'], false),
  tool('eval_get_experiment', 'Get instruction experiment', 'Read frozen variants, execution state and actual paired evidence.', { experimentId: uuid }, ['experimentId']),
  tool('eval_list_experiments', 'List instruction experiments', 'Discover frozen instruction experiments in a suite or project.', { suiteId: uuid, projectId: uuid }, []),
  tool('eval_decide_experiment', 'Decide instruction experiment', 'Record a decision and optionally adopt the candidate instructions in the unchanged source suite.', { experimentId: uuid, decision: { type: 'string', enum: ['keepCurrent', 'adoptCandidate', 'collectMoreEvidence', 'inconclusive'] }, expectedRevision }, ['experimentId', 'decision'], false),
  tool('eval_approve_baseline', 'Approve baseline', 'Approve complete saved app evidence and freeze its scoring contract.', { runId: uuid, assessmentId: uuid, note: text(4096), expectedRevision }, ['runId'], false),
  tool('eval_get_baseline', 'Get approved baseline', 'Read the current suite baseline, its selected assessment and evidence health.', { suiteId: uuid }, ['suiteId']),
  tool('eval_release_report', 'Release report', 'Apply the current app release policy to a saved local run and approved baseline.', { runId: uuid, baselineRunId: uuid }, ['runId']),
  tool('eval_project_release_report', 'Project release report', 'Evaluate every project suite with its latest saved evidence and current release policy.', { projectId: uuid }, ['projectId']),
  tool('eval_select_assessment', 'Select saved assessment', 'Select an existing assessment without altering original samples or judgments.', { runId: uuid, assessmentId: uuid, expectedRevision }, ['runId', 'assessmentId'], false),
  tool('eval_correct_judgment', 'Correct judgment', 'Save a human correction separately from immutable original judgments.', { runId: uuid, assessmentId: uuid, sampleId: uuid, correctedStatus: { type: 'string', enum: ['passed', 'failed', 'unscored', 'error'] }, correctedScore: { type: 'integer', minimum: 1, maximum: 4 }, reason: text(4096, 1), reviewer: text(160), expectedRevision }, ['runId', 'sampleId', 'correctedStatus', 'reason'], false),
  tool('eval_analyze_run', 'Analyze saved run', 'Use actual app coverage, repeatability, latency, token usage and compatible baseline comparison analysis.', { runId: uuid, baselineRunId: uuid }, ['runId']),
];
