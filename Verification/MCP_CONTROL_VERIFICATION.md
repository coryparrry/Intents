# MCP app-control verification

Latest verification: 3 October 2026. The default catalog contains 24 tools, with 111 actions available on demand (the original 110 plus explicit baseline approval). This extends PR #68's production workspace with shared native app controls. The original working checkout was not edited.

The initial 110-tool verification below is retained as historical evidence.

## Initial app-control result

- 110 unique MCP tools discovered, including the original 19. Typed workspace, review/calibration, batch/upload/export/schedule, runner and Intent Lab controls route through the same stores/coordinators as the UI.
- Final authenticated localhost HTTP run: **147 checks passed**, **100 distinct synthetic captured outputs** retained verbatim and unscored; **one separate real Apple on-device response** passed its configured criterion. Captured job ID: `97dded40-22d8-4b03-879a-396c3b6f8dcf`. Dataset revision: `803d65db115a492de9024efeb90fe0c77bb185086468547f5a3f698b5f2c55d5`.
- Checked operation retry identity, stale revisions, strict schemas, chunk integrity/preview/import, complete results, control CAS, schedule creation/deduplication, date rejection, exported report download, traversal denial and durable unapproved-build failure.
- Native accessibility and screenshot inspection showed **MCP verification / MCP controlled suite / Batch runs / Reports**, **MCP real Apple smoke Pass**, **1 of 1 saved / 1 passed / 0 errors**, on-device AFM 3 Core Advanced, Apple silicon, en_GB, macOS 27.2. Existing native layout and semantic colors retained. All instances of the isolated test build were closed afterward.

## Initial build and test evidence

Build product: `/private/tmp/intents-mcp-control-build/Build/Products/Debug/Intents.app`, bundle ID `com.coryparry.FoundationEvals`. Live connector process PID **73423** used `--evaluation-storage /private/tmp/intents-mcp-live/workspace --mcp-use-existing-credential`. The existing Keychain credential was used privately; it was not printed, rotated or committed.

This is an unsigned-development Debug build with linker ad-hoc signatures, not a notarized or distributed release. SHA256:

| Artifact | SHA256 |
|---|---|
| FoundationEvals executable | `a5053256ced6b91d536c44fc5bcec7c1c9f629567e6324f41f99f2435a4bb41b` |
| FoundationEvals.debug.dylib | `f929b88c583235c4704271bc9f4329c61d6905eb381d05a200f7c88314fd3e48` |

Commands/results:

```sh
swift test --package-path Packages/ProductionEvals --scratch-path /private/tmp/intents-mcp-core-tests -j 2
swift test --package-path Packages/ProductionEvals --scratch-path /private/tmp/intents-mcp-core-tests -j 2 --filter ProductionUploadTests
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-mcp-control-build -clonedSourcePackagesDirPath /private/tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO -only-testing:FoundationEvalsTests/MCPAppControlTests -only-testing:FoundationEvalsTests/MCPProtocolTests -only-testing:FoundationEvalsTests/MCPTransportRegressionTests test
python3 script/verify_mcp_app_control.py --native
```

The full core run passed all 19 existing tests, including 10,000-example resume without duplicate execution. One new assertion incorrectly compared raw versus persisted millisecond-rounded dates; it was corrected to compare the immutable revision. The subsequent focused run passed all **4 new upload/control tests**. Final native run passed **29 tests in 3 suites**, including export path alias/symlink and large persisted-result chunk regressions. Builds/tests ran sequentially with a maximum of two compile jobs; no automated UI test was executed. Python syntax check and `git diff --check` passed.

Live verification used the environment credential privately via the wrapper described in the guide. Log: `/private/tmp/intents-mcp-live-verification.log`. Final native log: `/private/tmp/intents-mcp-native-tests.log`; upload/core logs use the scratch-path names above with `.log` suffix.

Source identity was captured over 374 app/project/core/package inputs before commit/rebase. Sorted path/SHA256 manifest digest: `72498e8595efd4690cfc4d5e7ab8451f1fda202dbec5de16d6212ed22fc31e0e`. The local manifest is `/private/tmp/intents-mcp-verified-source.json`. After carrying only the new commit onto remote production head `91d5f469ea9644bee30fe11fe8fb0ef8664176f4`, all 374 input hashes remained identical. Newer fixture/CI changes were preserved; no native/core rebuild was required for that ancestry-only change.

## Independent review and retained failure lessons

Independent read-only reviews separately covered core authority/receipts/uploads/batches and shared native/device/installer/consent paths. Material findings were fixed, with reviewer rechecks clear. The final export fix was independently reviewed after the HTTP failure.

- Initial immediate post-launch HTTP call failed with `ConnectionRefusedError: [Errno 61] Connection refused`. Trace retained at `/private/tmp/intents-mcp-live-startup-failure.log`. Prevention: bounded initialization retry only for connection refusal.
- Final-build HTTP export check initially failed `AssertionError: export report manifest`. Trace retained at `/private/tmp/intents-mcp-live-export-pagination-failure.log`. Inspection then showed paths such as `<last eight UUID chars>/report.json`, caused by enumerated `/private/tmp` versus configured `/tmp`. Prevention: canonical root and guarded path components, alias/read compatibility and file/root symlink regression, complete manifest pagination. Final rerun passed.


## Slim catalog verification (latest)

- **24 default tools / 110 canonical actions.** Search returns at most ten short summaries, description returns one original schema, and separate read/apply entry points route through the original parser and authority. All original direct calls remain compatible.
- **16,274 versus 118,930 serialized schema bytes: 86.3% smaller.** This measures UTF-8 JSON bytes, not tokens or autonomous model selection accuracy.
- **50 native tests passed:** 34 discovery/authority/protocol/transport tests, 14 existing feature/provider tests and two existing hidden-action schema/report tests. Read/write denial, unknown/recursive actions, strict envelopes, pagination, full schema availability and canonical retry receipts are covered.
- **217 authenticated HTTP checks passed.** The driver loaded 19 needed advanced schemas and made 30 discovered calls using ordinary MCP calls. All 100 synthetic outputs matched their exact slot, example ID, source ID and original output; they remained unscored. One separate real Apple on-device response passed. Captured job: `57163c77-8a61-4b0f-a083-2d94580a6b4f`; dataset revision remains `803d65db115a492de9024efeb90fe0c77bb185086468547f5a3f698b5f2c55d5`.
- Native screenshot/accessibility inspection showed **MCP verification / MCP controlled suite / Batch runs / Reports**, **MCP real Apple smoke Pass**, **1 of 1 saved / 1 passed / 0 errors**. The existing layout/components/colors were retained. The isolated live listener was PID **1857**, bound to the exact Debug executable and isolated-storage arguments before credential use. All isolated test-build processes were closed.
- Independent read-only reviews covered authority/receipt compatibility and protocol/discovery/client behavior. The review's output-retention finding was fixed by comparing all 100 identity/output tuples. Reviewer rechecks were clear. The initial native test expectation incorrectly expected an authority error payload for a parser rejection; corrected regression verifies rejection before mutation. Failure trace: `/private/tmp/intents-mcp-discovery-first-native-failure.log`.

Commands completed sequentially with at most two compile jobs:

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-mcp-control-build -clonedSourcePackagesDirPath /private/tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO -only-testing:FoundationEvalsTests/MCPActionDiscoveryTests -only-testing:FoundationEvalsTests/MCPAppControlTests -only-testing:FoundationEvalsTests/MCPProtocolTests -only-testing:FoundationEvalsTests/MCPTransportRegressionTests test
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-mcp-control-build -clonedSourcePackagesDirPath /private/tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO -only-testing:FoundationEvalsTests/SchemaCustomizationTests/mcpCatalogPublishesRecursiveSchemaCustomizationKeys -only-testing:FoundationEvalsTests/ScenarioSavedExecutionReportTests/toolRequiresStableExecutionIDAndIsReadOnly -only-testing:FoundationEvalsTests/MCPFeatureTests -only-testing:FoundationEvalsTests/MCPProviderConfigurationTests test
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-mcp-control-build -clonedSourcePackagesDirPath /private/tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO '-only-testing:FoundationEvalsTests/SchemaCustomizationTests/mcpCatalogPublishesRecursiveSchemaCustomizationKeys()' '-only-testing:FoundationEvalsTests/ScenarioSavedExecutionReportTests/toolRequiresStableExecutionIDAndIsReadOnly()' test
python3 script/verify_mcp_app_control.py --native
```

The feature/provider command also initially included the two schema/report function filters without parentheses; those filters selected no tests. They were rerun with exact Swift Testing identifiers, and both tests are explicitly present in the successful log. Logs: `/private/tmp/intents-mcp-discovery-native-tests.log`, `/private/tmp/intents-mcp-discovery-compatibility-tests.log`, `/private/tmp/intents-mcp-discovery-schema-compatibility-tests.log` and `/private/tmp/intents-mcp-discovery-live-verification.log`. Python syntax validation and `git diff --check` passed.

The final 376-input app/project/core/package manifest is `/private/tmp/intents-mcp-discovery-verified-source.json`, SHA256 `b557aee329a58982a9b071f3c48781731121b39c67e62f3ac478db385a8e0773`. The live source snapshot is retained at `/private/tmp/intents-mcp-discovery-live-source.json`; only two compatibility-test descriptor lookups changed afterward. All production app/core source hashes and both artifact hashes stayed identical after the compatibility test builds:

| Debug artifact | SHA256 |
|---|---|
| FoundationEvals executable | `a5053256ced6b91d536c44fc5bcec7c1c9f629567e6324f41f99f2435a4bb41b` |
| FoundationEvals.debug.dylib | `e6b97668d18d13cb57f46ef52947e7b40d4bfab78dde1b3d757637f38cd79e79` |

This remains a local unsigned-development Debug artifact. The scripted driver knows target action names; these checks establish on-demand discovery/transport and preserved behavior, without qualifying every MCP host or measuring an autonomous agent's tool-selection accuracy.

## Qualification boundaries

The connector must already be enabled/authenticated. Product/domain operations are exposed; MCP does not automate window pixels, bootstrap its own access, launch arbitrary command workers or fabricate operator approval/device trust. Physical pairing, Siri/device execution, external judges, installer execution against a real consumer app and real production traffic were not exercised in this live run. They retain existing consent, trust, readiness and review safeguards.

Existing PR #68 production release-gate review findings remain open in their own review scope. These MCP checks establish controls, transport, retained evidence and a small real Apple model response; they do not qualify all underlying production gates or a distributed release.

## Pre-merge fixes verification (latest)

All seven findings from the review of `ee38e7a` are repaired: connection-bound judge credentials; explicit evidence-bound baseline approval; one report transaction across control/cost/results/reviews/baseline; critical case-to-source mapping at native job creation with frozen source identities preserved for clones; Resume captures the clicked job and disclosure choice; reconciled responses count as reviewed; one verified dataset reader per report. Two independent source reviewers found no remaining material issues after correcting error-bearing baseline eligibility and overlapping source/example IDs during cloning.

- **28 core tests passed** in three suites on the final source, including ten-thousand-example resume, baseline approval/invalidation/cancellation/error eligibility, imported critical mapping, cross-namespace clones, concurrent cost reports and reconciliation. Log: `/private/tmp/intents-pr68-fix-core-complete.log`.
- **76 native tests passed** in 10 suites on the final app/core source, including credential binding, MCP confirmation/stale-evidence/retry receipts, Resume selection changes, discovery, transport, feature/provider compatibility, judge criteria, and the exact saved-report schema selector. Log: `/private/tmp/intents-pr68-fix-native-final.log`.
- **49 CLI integration assertions passed** against the final CLI binary: baseline confirmation/invalidation, real custom worker subprocesses, bounded resume, capture, review, export, timeout and backend isolation. Log: `/private/tmp/intents-pr68-fix-cli-integration.log`.
- **228 authenticated HTTP checks passed**, with 24 default tools / 111 canonical actions, 16,274 / 119,862 schema bytes, 20 advanced schemas loaded on demand, and 31 discovered calls. All 100 synthetic captured identity/output tuples matched exactly and remained unscored. A separate real Apple on-device response passed; explicit baseline approval persisted. Log: `/private/tmp/intents-pr68-fix-live.log`. Captured job: `e17d5713-4865-4477-9335-0a205d407cc9`. Dataset: `803d65db115a492de9024efeb90fe0c77bb185086468547f5a3f698b5f2c55d5`.
- **Deterministic cross-process cost race passed.** LLDB stopped the report after reading controls while holding its transaction. A concurrent worker blocked. The earlier snapshot reported completed=0/cost=0/exit=20; after release, the worker's report showed completed=1/cost=2/exit=20 under budget=1. No stale passing gate. Logs: `/private/tmp/intents-pr68-fix-cost-race.log` and `/private/tmp/intents-pr68-fix-race-worker.log`.
- **Native UI inspected and exercised.** Screenshot/accessibility inspection showed the existing Reports layout and bordered approval control. Approval required a note, persisted the displayed evidence, then disabled its button and showed the approval status. Authenticated MCP confirmed the same note and evidence revision. Pausing/resuming invalidated the previous approval before native reapproval. Jobs controls were inspected. PID 38888 was bound to the exact Debug executable and isolated storage arguments before credential use. The app was closed afterward. Evidence: `/private/tmp/intents-pr68-fix-ui-evidence.json`.

The 380-input app/project/core/package/test/CLI manifest is `/private/tmp/intents-pr68-fix-verified-source.json`, SHA256 `5e4ffcbc50030bbe33dc444de553afd49ad8c190901412d3ed32b489e0977566`. Debug executable SHA256 `a5053256ced6b91d536c44fc5bcec7c1c9f629567e6324f41f99f2435a4bb41b`; debug dylib SHA256 `2599216c2a4840648ca7f20f06b98fd16c233daa0b0d0e59aaf6b0e54a94305b`. This is an unsigned local development artifact.

Failure evidence is retained: the first core approval test showed pause/resume could restore a previous evidence hash (`/private/tmp/intents-pr68-fix-core.log`); a durable control mutation ID now prevents that. An intermediate compile exposed a missing mutation field (`/private/tmp/intents-pr68-fix-core-targeted.log`), corrected before passing rechecks. Initial native selectors included nonexistent saved-report/judge suite names; the final run uses selectors verified from declarations and explicitly contains the saved-report test.

Credential tests exercise the binding codec with fixture secrets; actual Keychain persistence rollback was source-reviewed, without touching real judge keys. Full report scans serialize worker writes while holding the shared lock. These checks establish local behavior, without qualifying distribution, every MCP host, or autonomous action selection. Original checkout and operator data were preserved. No merge was performed.

Final commands (sequential builds, two compile jobs):

```sh
swift test --package-path Packages/ProductionEvals --scratch-path /private/tmp/intents-mcp-core-tests -j 2
swift build -j 2 --product intents-evals --scratch-path /private/tmp/intents-pr68-fix-cli-build
python3 script/test_production_evals.py /private/tmp/intents-pr68-fix-cli-build/debug/intents-evals
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-mcp-control-build -clonedSourcePackagesDirPath /private/tmp/IntentsReviewFixes-DD64/SourcePackages -jobs 2 OTHER_SWIFT_FLAGS='$(inherited) -j2' CODE_SIGNING_ALLOWED=NO -only-testing:FoundationEvalsTests/JudgeCredentialBindingTests -only-testing:FoundationEvalsTests/MCPActionDiscoveryTests -only-testing:FoundationEvalsTests/MCPAppControlTests -only-testing:FoundationEvalsTests/MCPProtocolTests -only-testing:FoundationEvalsTests/MCPTransportRegressionTests -only-testing:FoundationEvalsTests/MCPFeatureTests -only-testing:FoundationEvalsTests/MCPProviderConfigurationTests -only-testing:FoundationEvalsTests/EvaluationJudgeTests '-only-testing:FoundationEvalsTests/SchemaCustomizationTests/mcpCatalogPublishesRecursiveSchemaCustomizationKeys()' '-only-testing:FoundationEvalsTests/ScenarioSavedExecutionReportTests/toolRequiresStableExecutionIDAndIsReadOnly()' test
python3 script/verify_mcp_app_control.py --native
python3 -m py_compile script/test_production_evals.py script/verify_mcp_app_control.py
git diff --check
```
