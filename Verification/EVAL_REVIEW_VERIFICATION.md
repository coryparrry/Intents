# Eval review verification

Feature branch: `codex/eval-review-workspace`. Feature-only base: `078fa0c96abf60ebe67a436fa5a00f206b7f00e4` (PR #66). The branch is independent of gh-stack; merge only after that stack lands. The original dirty checkout is unchanged.

## Proven

- Native Debug app and unit/UI test targets compile using isolated DerivedData and the existing package cache, two jobs.
- 153 targeted tests in five suites pass: EvaluationReviewWorkflowTests (23), EvaluationDevelopmentWorkflowTests, EvaluationCompatibleJudgeClientTests (including its integrity extension), MCPStoreAuthorityTests and MCPProtocolTests.
- Tests cover old decoding, human annotations, proposals, source identity, persistence/rollback, pattern counts, deterministic discovery, regression provenance/context/limits, judge partitions/calibration, missing/corrupt image evidence, local-resource clearing, retained drafts and draft write failure.
- Separate Sol 6.1 evidence/MCP and UI reviews completed. Material findings were fixed, rechecked by those reviewers and tested.
- The existing ordered tool-catalog/schema assertion now covers both new tools.

Latest passing test evidence: `/private/tmp/intents-eval-review-final2.log` and `/private/tmp/intents-eval-review-final2.xcresult`. Earlier failed build/catalog logs are retained beside them; failure traces and fixes are summarized in EVAL_REVIEW_WORKLOG.md.

## Pending native acceptance

The Mac is locked and CUA could not unlock it. No native review appearance or interaction claim is made. EvaluationReviewUITests covers blind review/save/relaunch/promotion, unfinished-note navigation, pattern drill-down and an explicit narrow window. Execute it after unlocking, then inspect the real Review page in light/dark appearance and at the existing 1000-point minimum width. Use the exact app at `/private/tmp/intents-eval-review-build/Build/Products/Debug/Intents.app` with isolated `--evaluation-storage` and `--disable-mcp-autostart`.

Fixture data proves software behavior only. These checks do not prove a live Apple model response, real app state change, Siri completion, release qualification or distributed build.
