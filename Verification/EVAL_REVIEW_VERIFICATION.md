# Eval review verification

Feature branch: `codex/eval-review-clean`. Base: `2477e157c` on `main`, after PRs #51–#66 merged. This replaces PR #67 and is the lower layer for the production-evaluation PR #68. The original dirty checkouts are unchanged.

## Proven

- Native Debug app and unit/UI test targets compile using isolated DerivedData and the existing package cache, two jobs.
- Before the sidebar follow-up, 153 targeted tests in five suites passed: EvaluationReviewWorkflowTests (23), EvaluationDevelopmentWorkflowTests, EvaluationCompatibleJudgeClientTests (including its integrity extension), MCPStoreAuthorityTests and MCPProtocolTests. On the final sidebar source, all 23 review workflow tests passed again and the native app/unit/UI targets compiled.
- Tests cover old decoding, human annotations, proposals, source identity, persistence/rollback, pattern counts, deterministic discovery, regression provenance/context/limits, judge partitions/calibration, missing/corrupt image evidence, local-resource clearing, retained drafts and draft write failure.
- Separate Sol 6.1 evidence/MCP and UI reviews completed. Material findings were fixed, rechecked by those reviewers and tested.
- The existing ordered tool-catalog/schema assertion now covers both new tools.

Passing test evidence: `/private/tmp/intents-eval-review-final2.log` and `.xcresult` (153 tests); `/private/tmp/intents-eval-sidebar-final.log` and `.xcresult` (23 tests on final sidebar source). The final command used the FoundationEvals scheme, macOS Debug destination, isolated DerivedData/package cache, two jobs, `-parallel-testing-enabled NO`, `-only-testing:FoundationEvalsTests/EvaluationReviewWorkflowTests`, and the existing Apple Development signing identity. Failure traces and fixes are summarized in EVAL_REVIEW_WORKLOG.md.

## Native fixture acceptance

After the Mac was unlocked, CUA inspected the actual latest app at `/private/tmp/intents-eval-review-build/Build/Products/Debug/Intents.app` using isolated `--evaluation-storage` and `--disable-mcp-autostart`. Native accessibility states and screenshots in the task show:

- Evaluations and Traces appear directly beside Overview and Intent Lab. Evaluations opens Review; Traces lists the selected suite's saved runs and opens the existing viewer. Legacy evidence without captured timeline offsets is labelled honestly.
- An unfinished verdict, note and tag survived a sidebar roundtrip. Save confirmed the failure; Patterns showed one reviewed example/one unique case and drilled back into its source.
- Regression creation started with an empty expected answer and disabled submission. Supplying `Friday` created a second case with the captured prompt and verified reference answer.
- After quitting and reopening, the saved verdict, note, tag and regression case remained intact.
- The native Window > Move & Resize > Left action produced a 2002-pixel-wide screenshot at 2x scale (about 1001 points, the supported minimum). The sidebar destinations remained visible; Review used the existing compact pane selector. Samples and Patterns remained readable without horizontal clipping.
- A separate empty workspace showed No saved traces yet; Open evaluations selected Review and showed Choose a saved output.

Light appearance was visually inspected. An app-only dark launch argument did not change the rendered appearance; dark appearance remains unverified, without changing the user's system preferences.

## XCTest startup limitation

EvaluationReviewUITests includes save/relaunch/promotion, retained drafts, patterns, narrow layout, sidebar roundtrip and empty states. The native UI runner was killed before bootstrap under unsigned, ad-hoc and existing Apple Development signatures. No XCTest UI assertions ran; the development-signed runner verified on disk. Results are retained at `/private/tmp/intents-eval-sidebar-native.xcresult`, `/private/tmp/intents-eval-sidebar-signed-native.xcresult`, and `/private/tmp/intents-eval-sidebar-development-native.xcresult`, with corresponding logs. Manual native checks above provide the interaction evidence; compilation is reported separately.

Fixture data proves software behavior only. These checks do not prove a live Apple model response, real app state change, Siri completion, release qualification or distributed build.
