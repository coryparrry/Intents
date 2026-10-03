# Complete MCP control of Intents

Active work: extend the isolated production-evals branch and PR #68. Keep the original intents stack and dirty checkout unchanged.

The MCP API must control the same domain services and observable stores as the app. The existing suite connector and new batch workflow must not form separate workspaces. UI layout and styling remain unchanged.

## Acceptance contract

1. Projects/suites: list, inspect, create, rename, duplicate, archive, select; edit the full suite including judge/release configuration and references; inspect readiness and model state.
2. Evaluation evidence: run/cancel/inspect, analysis and traces; baseline approval, instruction experiments and decisions; review/proposal decisions, promotion, failure patterns and judge calibration.
3. Production batches: bounded dataset upload/preview/import and suite freezing; native/captured jobs, clone/start/pause/resume/cancel, results/traces/reports, coherent downloadable exports, workers and schedules. Large datasets use bounded chunk uploads, not arbitrary filesystem paths.
4. Developer/device and Intent Lab workflows: expose the existing discovery, explicit pairing/trust, configuration, authoring, preflight, execution/cancellation and saved evidence through shared app coordinators. Preserve local/device consent and quarantine/readiness checks; do not invent hardware evidence or bypass trust.
5. Control integrity: explicit target IDs, revision checks, stable mutation IDs for retryable creation, bounded inputs/results, and required confirmation for destructive or operator-approved decisions. Preserve subject/judge disclosure checks and execution ownership across GUI/MCP. Never expose connector credentials or launch arbitrary shell commands.
6. Schema/discovery and workflow instructions describe every operation. No tool may acknowledge a mutation or start that failed underneath. Asynchronous runs return durable IDs/status and retain the same UI evidence.
7. Add meaningful parser/authority/transport and failure-path tests. Exercise the actual connector with an isolated store, including 100 distinct fixture outputs and a small real Apple model check. Independently review the stable core/control and native/UI scopes. Close test apps at completion.

## Evidence boundaries

API coverage means product workflows, not emulating window pixels or bootstrapping an untrusted connector remotely. The connector must already be running/authenticated. External apps supply their own sanitizer and pairing evidence. Worker/reviewer metadata is attribution, not attestation. Live-device and production-traffic qualification remain separate.

## Worklog

- Inventory found missing project/suite management, experiment/baseline/review decisions and all production controls. Current MCP only reads Intent Lab evidence; the shared coordinator must expose its guarded actions.
- Implement shared app control ownership first, then typed domain tools, schemas, tests and actual connector verification. Existing production/source evidence remains at commit e20340c670ad05c35d694606d353829c91ee98aa.

- Shared UI/MCP ownership and typed controls implemented for workspace/evidence, batch jobs/datasets/schedules/exports, runners and Intent Lab. Existing UI layouts/components are retained.
- Independent reviewers found disclosure-field forgery, mutable-control CAS, upload identity, async acknowledgment, installer routing/bounds and stale editor-state issues; fixed these paths and added regression coverage. Native build passed.
- Existing production regression run passed its 19 prior tests, including 10,000-example resume; one new identity assertion compared rounded dates and was corrected. All four new upload/control tests now pass. Final targeted native verification passed 29 tests. Authenticated HTTP MCP verification passed 147 checks across 110 discovered tools, retaining 100 distinct captured outputs and one separate real Apple response; the matching native report was inspected.

- Final live verification exposed incorrect relative export names through macOS /tmp aliases. Canonicalized the export root, retained symlink denial, added an integration regression and reran the native/HTTP checks successfully. The verifier now reads every export page and waits through the short connector startup window.
- Native UI inspection confirmed MCP-selected Batch runs / Reports, the correct project/suite and saved Apple response, using the existing layout/components/colors. All processes from the isolated test build were closed.
- Remote PR #68 was independently moved onto replacement #70 (codex/eval-review-clean). Carried only the new MCP commit onto remote production head 91d5f469ea9644bee30fe11fe8fb0ef8664176f4, preserving the newer fixture/CI changes. The 374 app/project/core/package input hashes are identical before/after rebase.
- Existing production-gate review findings on PR #68 remain a separate review scope; this work verifies control/transport/evidence behavior and does not claim production release qualification.

## Slim default catalog follow-up

Completed: preserve complete app control while reducing the upfront tool/schema load.

- Advertise 20 common workspace/evaluation/batch operations plus four bounded discovery/invocation tools (24 total). Keep all 110 original operations registered and directly callable for compatibility.
- Search returns short paginated action summaries; description returns one exact original schema. Read/write invocation validates the selected original schema and read-only classification before routing to the unchanged authority. Preserve original target IDs, receipts, revisions and consent. No dynamic tools/list changes or special host tool-search support are required.
- Reject recursive discovery invocation, unknown actions, extra envelope fields and attempts to use read invocation for a mutation. Original operation IDs produce the same receipt through direct or discovered invocation.
- Measure serialized catalog size against the prior 110-operation catalog; target at most half the upfront schema bytes. Test discovery coverage/pagination, invocation boundaries and retry identity, then exercise the authenticated HTTP batch workflow through discovered actions. Existing UI stays unchanged.
- Reuse independent read-only reviewers for discovery/protocol and authority/compatibility scopes after the change is stable. Keep builds/tests sequential with two compile jobs.

- Final catalog advertises 24 tools and retains all 110 canonical actions. Serialized schema payload is 16,274 versus 118,930 bytes (86.3% smaller). The compact suite configuration action is upfront; the large legacy replacement schema remains available on demand and directly callable.
- Native verification passed 34 discovery/authority/protocol/transport tests plus 16 existing suite/provider/schema/report compatibility tests (50 total). Exact function filters require Swift Testing's parentheses; execution counts were checked to confirm the two schema/report tests ran.
- Authenticated HTTP verification passed 217 checks, loaded 19 advanced schemas and made 30 discovered calls. It retained all 100 fixture outputs with exact slot/example/source identities, then completed one separate real Apple model response. Native screenshot/accessibility inspection confirmed the matching report; all isolated test-build processes were closed.
- Independent reviewers cleared routing/authority and protocol/discovery scopes. Their verifier finding was fixed by comparing every retained output and identity, not only uniqueness. The first native run exposed a test expectation that treated a parser rejection as an authority payload; the retained failure trace and corrected test now verify rejection before mutation.
- Final source identity and artifact hashes are recorded in Verification/MCP_CONTROL_VERIFICATION.md. Only two compatibility-test lookup changes followed live verification; app/core inputs and executable/debug-dylib hashes stayed identical. These results measure schema bytes and actual connector behavior, not autonomous model tool-selection accuracy or production release qualification.

## Pre-merge findings repair (complete)

Active scope: fix the seven findings recorded against ee38e7a57399b4d9c19be512b4483df07893821c. Preserve the current UI components/layout/colors and unrelated checkout work.

- Bind judge credentials to saved connection ID/provider/endpoint; reject altered worker metadata and unbound legacy credentials until explicitly re-entered. Preserve rollback bytes.
- Add explicit production baseline approval bound to the frozen job and complete evidence revision, available through UI, CLI and on-demand MCP. Reject cancelled, changed or ineligible baselines.
- Use a coherent report transaction and one verified dataset reader; count reconciled results as reviewed.
- Resolve critical case IDs to dataset source IDs using exact IDs or metadata.suiteCaseID, and reject missing mappings before saving a job.
- Capture the clicked job and disclosure decision through asynchronous resume. Add failure-path and interaction regressions, recheck the original fixture failures, inspect the actual native UI, and independently review stable fixes. Keep builds/tests sequential with two compile jobs.

Completed all seven fixes and regression checks. See Verification/MCP_CONTROL_VERIFICATION.md for exact commands, source/artifact identity and evidence boundaries.
