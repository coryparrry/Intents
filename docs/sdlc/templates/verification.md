# Verification evidence: {{TITLE}}

Change: {{CHANGE_ID}}
Checked revision / worktree identity: {{REVISION_AND_DIRTY_DIFF_ID_IF_NEEDED}}
Related spec / plan revisions: {{ARTIFACT_REVISIONS}}
Overall result: not run

## Executed checks
| Time | Command and working directory | Exit status | Actual observation | Evidence location |
| --- | --- | --- | --- | --- |
| {{TIME}} | {{COMMAND}} | {{EXIT_CODE}} | {{OBSERVATION}} | {{CI_RUN_LOG_OR_SCREENSHOT}} |

## Regression proof
Failing-before-fix test and observed cause: {{FAILURE_EVIDENCE_OR_NOT_APPLICABLE}}
Accepted test checkpoint: {{TEST_COMMIT_OR_REVIEW_REFERENCE}}
Passing-after-fix result: {{SUCCESS_EVIDENCE_OR_NOT_RUN}}
Test unchanged during fix / reviewed exception: {{DIFF_EVIDENCE}}

## UI and neighboring flows
{{VISUAL_COMPARISON_AND_CHANGED_PLUS_NEIGHBORING_BEHAVIOR_OR_NOT_APPLICABLE}}

## Independent verification
{{VERIFIER_REPORT_OR_NOT_RUN_WITH_REASON}}

## Unperformed checks, failures, and limits
{{EXPLICIT_GAPS_AND_REQUIRED_NEXT_ACTIONS}}

## Evidence retention
Use concise literal output excerpts and durable access-controlled links. Never invent outputs or commit secrets, customer data, or unrestricted sensitive logs. PR/CI remains authoritative when designated; this file is an index, not a second approval system.
