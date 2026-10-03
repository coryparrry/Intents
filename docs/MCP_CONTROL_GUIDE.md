# Control Intents through MCP

Intents' authenticated localhost connector now uses the same workspace, batch store, developer runners and Intent Lab coordinator as the native UI. The connector must already be enabled and authenticated. The standalone Apple Foundation Evals plugin remains a separate product/store.

## Discover and inspect

The default catalog advertises **24 tools**: 20 common workspace/evaluation/batch controls and four discovery/invocation tools. Read `eval_get_state` and `eval_workspace_state` first. All 110 original operations remain available.

For advanced work, search by task using `eval_find_actions` with `query`, optional `domain` and `limit` (default 5, maximum 10). Domains are `workspace`, `evaluations`, `production`, `reviews`, `judges`, `runners` and `intentLab`. Search returns short summaries and `nextOffset`; load one exact schema using `eval_describe_action`. Use the returned `invokeWith` entry point with the action name and its exact arguments:

```json
{"name":"eval_read_action","arguments":{"action":"eval_intent_state","arguments":{}}}
```

A mutation uses `eval_apply_action` with the original operation ID, revision and confirmation fields inside its nested `arguments`. Read invocation rejects mutations before execution. Both entry points delegate to the original typed parser and authority, so retries and approvals are unchanged.

Names below identify original actions. If a name is absent from the default catalog, discover/describe it and use the indicated entry point. Existing direct calls remain supported for compatibility; reconnect/refresh tool discovery after updating the app. Search and invocation work with ordinary MCP clients and do not require dynamic tool-list support. `eval_workspace_state` returns the full selected native suite and its current revisions; full native JSON uses Foundation's date encoding. Production dataset, job, review and schedule JSON uses Unix milliseconds.

New mutations take a caller-generated `operationID`. Retry the identical tool and arguments after a lost reply. The persisted receipt identifies duplicate results and rejects reuse with changed arguments. `eval_operation_status` distinguishes committed actions, dispatched work, completed/failed work and interrupted ownership. An interrupted operation is never automatically replayed: inspect its exact target before making a new decision. Retain the operation ID while polling. Large completion results use a private, bounded artifact; receipts advertise its size/digest and `eval_operation_result_read` downloads chunks.

## Workspace and ordinary evaluations

Create/select/rename/duplicate/archive projects and suites with `eval_project_*`, `eval_suite_*` and `eval_workspace_select`. Mutations require `expectedWorkspaceRevision`; suite definitions and evidence decisions also identify the project/suite and their revision. `eval_workspace_navigate` changes the same visible sidebar selection and batch pane as the UI.

Use `eval_suite_configure` for complete native model, feature, judge and release-policy configuration. Retain suite identity and attachment metadata; upload/delete attachments using the existing byte-based tools. Disclosure approval fields are server-owned. Approve the exact current connection digest through `eval_judge_disclosure_approve`, with operator authorization.

Existing `eval_start_run/get_run/cancel_run/list_runs/analyze_run`, trace resources and release reports remain available. Interactive suites allow at most 100 planned responses. Baselines, instruction experiments, operator review/proposal decisions, regression promotion, failure patterns, calibration, saved assessment selection and reassessment have dedicated tools. A dispatched receipt acknowledges work; inspect saved runs/calibration reports before claiming a pass. `eval_run_save_retry` retries pending evidence storage without regenerating output. Repository linking preserves conflicting definitions and requires confirmation.

## Large batches

1. Prepare JSONL `ProductionExample` rows. A minimal row is `{"id":"case-1","sourceID":"source-1","prompt":"Reply with Friday","expected":"Friday","partition":"regression","metadata":{"task":"weekday"}}`. Partitions are `development`, `regression` and `test`. One source cannot cross development and held-out partitions. Add `capturedOutput` and optional `feedback` to review original production responses.
2. Calculate SHA256 of the complete raw file. Call `eval_production_upload_begin` with an upload UUID, name/version, chunk count, total bytes and hash. Upload raw byte chunks as base64, each at most 1 MiB. Chunks may split lines or UTF-8 sequences. Inspect received indexes with `upload_status`; identical bytes at the same index are safe, conflicting bytes fail.
3. `upload_preview` verifies the complete digest and seals the source. `upload_finish` requires that digest; production data also requires confirmed redaction. Discarded upload IDs cannot be reused. Limits are 10 pending uploads, 1,024 chunks, 1 GB and one million examples.
4. `job_create` freezes the selected native suite or creates captured-output review. Native options cover repetitions, targets, chunks, attempts, deadlines, elapsed/cost budgets, cohorts, release gates and compatible baselines. Credentials are resolved by the app, never frozen into context. Captured review retains the original output and makes no subject inference calls.
5. Start with the exact frozen job revision and poll `job_get`, `results` and `result_get`. Native execution uses the same admission/disclosure and evaluator as the UI. Large result lists return summaries; a selected result retains its full original evidence. Context and export bytes have bounded chunk readers.
6. Pause/cancel/resume through `job_control` using both the frozen job revision and returned mutable `controlRevision`. Cancelling retains evidence. Uncertain side effects require assigned, verified reconciliation. Review actions require operator authorization; do not label an agent's proposed judgment as a human review.
7. Save schedules using their current revision, or `absent` for a new ID. `schedule_tick` creates due jobs once; execution is explicit while the app/worker is running. Worker provenance appears in `production_state`. Evidence exports are stored under app-owned `MCPExports`; list/read exact relative paths, without arbitrary filesystem access.

The native app runs jobs on this Mac. Configured command workers still use the documented CLI; MCP does not launch arbitrary executables. Counts, cohort gates and source confidence describe retained evidence, not proof of real production traffic or physical Siri coverage.

## Developer runners and Intent Lab

Discover runners, select an advertised runner/feature without inference, pair, trust only after comparing the physical code, dispatch a suite and cancel/poll its saved run. Trust secrets and pairing codes are omitted from state.

`eval_intent_state/get/select/connect/draft/new/save` control the shared authored requirement and target. Read discovered IDs rather than inventing app/test products. Full draft replacement retains selected target/integration identity and clears stale editor errors. Build approval authorizes the selected project's build scripts; installed integration verification and route readiness remain separate.

The installation tools inspect existing target IDs, preview the same Basic/Siri templates as the UI, and apply an exact reviewed session preview. Apply rechecks prior bytes/path safety, verifies the result and selects that project/workspace. It clears build trust/readiness. Previews are session-bound and bounded to fit durable receipts; after restart, preview again before approving a new apply.

Execution includes a complete requirement, a partial `diagnostic` with `lanesJSON`, saved reruns, collections and failed-batch reruns. Collections, approved variations/suggestions, saved-evidence assessment, persistence recovery, quarantine release and evidence exports retain the existing coordinator's safety and readiness guards. Physical device/Siri qualification requires actual device evidence.

## Verification

`script/verify_mcp_app_control.py` exercises an already-running isolated app with `MCP_AUTHORIZATION` set to its existing credential. It sends credentials only to a localhost `/mcp` endpoint, never logs them, discovers only needed advanced schemas, measures default catalog bytes, validates read/write denial and processes 100 distinct synthetic original outputs and checks retries, revisions, export bytes, scheduling and approval denial. `--native` separately performs one real on-device response. It does not use real production data, external judges or physical Siri.
