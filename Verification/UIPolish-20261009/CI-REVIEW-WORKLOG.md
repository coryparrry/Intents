# PR 131 CI and review follow-up — 2026-10-10

Scope: fix PR 131 CI failures and verified review comments; preserve unrelated local work.
Source: isolated temporary checkout of PR head e233262f3. No other checkout is modified.

Inventory complete at initial collection: 3 unresolved inline threads, 1 general status comment,
1 review submission summarizing those findings. All 3 unique findings are Fix now; no deferred findings.

Verified triggers and fixes:
- More than 24 runs with device clock skew exclude the highest saved history sequence. Select
  by durable sequence and timestamp before limiting; keep selected points chronological for display.
- Two suites named Smoke share a chart series. Group by stable suite ID, preserving names in tooltips
  and accessibility labels. Suite creation permits duplicate names, so names are not identities.
- Cancellation or early stopping after one case finishes hides that case's recorded failure.
  Determine completeness from each case's repetition count; preserve pending/partial and stale states.
All three claims reproduce from current source; no later guard prevents the reported behavior.
Focused regression tests cover each trigger and adjacent legacy/partial/rename cases.

CI inventory: release note override missing; portable cancellation test times out waiting for
fake host readiness. Added and locally validated the active release-note override in the PR body.
The unmodified portable target passed all 307 tests locally, including host cancellation, while
many independent fixtures occupied the scheduler for 16–19 seconds. Serialize ScenarioContractsTests
so its synchronous process/filesystem fixtures do not compete with its readiness deadlines.
Production cancellation behavior remains unchanged. Hosted rerun will qualify this correction.

Local full-package test limitation: IntentLabTestingTests cannot load against this Mac's installed
AppIntentsServices runtime (missing resolveValue symbol from the Xcode 27 SDK); other targets ran.
Run the relevant FoundationEvalsPortableTests product separately; hosted runtime is authoritative
for the full package.

## Validation

- `swift test --test-product FoundationEvalsPortableTests --jobs 2 --enable-code-coverage`:
  307 Swift Testing tests passed; the product's XCTest checks also passed. Cancellation readiness
  and cleanup passed in 2.488 seconds; the serialized suite finished in 64.989 seconds.
- `python3 -m unittest script.tests.test_release_notes`: 13 passed.
- `python3 -m unittest script.tests.test_ci_run_tests script.tests.test_ci_routes`: 40 passed.
- Active PR event passed `script/release_notes.py validate-event`.
- Native Debug build and WorkspacePresentationTests: 20 passed, including all three new regressions.
- Final combined WorkspacePresentationTests and UISnapshotTests: 22 passed.
- Snapshot suite recheck after fixing the capture window's sizing: 2 passed.
- Inspected the final case-view and chart PNGs in PR-Screenshots. The completed case displays
  Failed 2 of 2 attempts, pending cases remain Not run, and same-named suites form separate lines.
  These are native renders of the affected views with synthetic fixtures.
- Reviewed the stable scoped diff for comparator consistency, suite identity, incomplete/stale
  verdict boundaries, and process-test cleanup. No remaining actionable issues. `git diff --check` passed.
- Native windows close in test cleanup; the test host exited. No simulator used.

Native commands (two build workers, parallel test execution disabled):

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-presentation.xcresult -only-testing:FoundationEvalsTests/WorkspacePresentationTests test
INTENTS_SNAPSHOT_DIR=/private/tmp/intents-pr131-review-screens TEST_RUNNER_INTENTS_SNAPSHOT_DIR=/private/tmp/intents-pr131-review-screens xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-native-final.xcresult -only-testing:FoundationEvalsTests/WorkspacePresentationTests -only-testing:FoundationEvalsTests/UISnapshotTests test
INTENTS_SNAPSHOT_DIR=/private/tmp/intents-pr131-review-screens TEST_RUNNER_INTENTS_SNAPSHOT_DIR=/private/tmp/intents-pr131-review-screens xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-render-final.xcresult -only-testing:FoundationEvalsTests/UISnapshotTests test
```

## Delivery boundary

Commit/push these fixes to PR 131, resolve the three verified threads after publication,
and verify hosted checks on that exact commit. The PR remains open for review.

## Refreshed review

The review of 869124a36 added 3 threads: 1 Fix now and 2 Ignore (informational), bringing
the complete inventory to 4 verified bugs and 2 intentional presentation choices.
- Sparkline latest marker: chronological geometry picked an older scored run under clock skew.
  Preserve historySequence on chart points and choose the marker by saved order. Keep the
  latest scored marker when a newer run is unscored; legacy points fall back to dates.
- Report default: intentional result-first navigation in this PR. Workflow trace remains a
  peer tab, covered by the initial repeated-navigation UI checks. No failure trigger was alleged.
- Markdown response display: intentional presentation-only formatting. RunDetailView.copyResponse
  copies result.response directly, and the stored response/scoring input remains untouched.
  The comment reports a display choice without a persistence or scoring bug.
The final focused native run passed 23 tests (21 presentation + 2 render tests). Inspected
review-latest-saved-sparkline.png: the latest saved failed run is marked on the left despite
an older saved run having a later date. Regression coverage also checks newer unscored runs,
legacy date fallback, and no scored runs. Reviewed the final diff; git diff checks passed.
No persistence format or scoring behavior changes. The new point metadata is only presentation data.

## Hosted UI qualification

The native CI job on 8f6f024e4 built successfully and passed core tests, then failed 6 of 18 UI tests.
Full logs and exported accessibility hierarchies identify stale Report chart assertions and
viewport/focus problems on the preview runner's 1024x768 display. A reset test explicitly requested
a 1400-point window and attempted to click the toolbar at x=1323, outside the display. Footer case
actions did not activate: subsequent hierarchy showed the edited original case and no added case.

Update lifecycle checks to open Performance for charts, use 1000x700 verification windows, activate
the app after the menu command presents its window, and auto-hide the Dock in the disposable CI
runner. Reset cancellation now explicitly reopens Workflow trace before checking trace controls.
These changes retain every original assertion and do not alter production behavior or local Dock settings.
Added an explicit case-row increment check before editing a newly added case, so a failed footer
action cannot silently turn into an edit of the previous case. Local build-for-testing succeeded
for the final UI test source. Pinned actionlint 1.7.12 passed, and 51 CI routing/xctestrun tests passed.
Local targeted UI execution could not initialize: Xcode timed out enabling automation mode before
any tests ran. Hosted UI execution remains the qualification gate for these test-harness changes.

```sh
INTENTS_SNAPSHOT_DIR=/private/tmp/intents-pr131-review-screens TEST_RUNNER_INTENTS_SNAPSHOT_DIR=/private/tmp/intents-pr131-review-screens xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-sparkline.xcresult -only-testing:FoundationEvalsTests/WorkspacePresentationTests -only-testing:FoundationEvalsTests/UISnapshotTests test
```

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO build-for-testing
python3 -m unittest script.tests.test_ci_routes script.tests.test_ci_ui_xctestrun
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 -ignore 'label "xcode-27" is unknown'
```

## Integration and cross-suite review

A concurrent update integrated reviewed Automation and release-refresh dependencies on top of
43191735f; preserve those changes at 0de189e6f. Its native CI build found a missing Automation
case in WorkbenchStatusBar. Include Automation with the existing local-evidence status summary.

The refreshed review added one verified cross-suite clock-rollback bug. Restore the history
sequence maximum from all workspace run histories at startup, including archived suites and
other projects. Carry that floor through snapshot and active-run recovery, advancing it after
each recovered run. Existing saved sequences and the persistence format remain unchanged.

Add an integration regression that saves six runs with future sequence/timestamp metadata,
restarts with a different empty suite selected, saves a new run, checks the real overview loader
and six-item timeline, and restarts again to verify monotonic ordering continues. This simulates
a clock rollback without changing the machine clock. Qualification passed: 34 presentation/lifecycle
tests, then all 72 development-workflow tests, including the named restart regression. The method
filter omitted the new Swift Testing method in the first run; the second suite-level run confirms
it executed and passed. Reviewed the scoped diff; git diff --check passed.

A concurrent 664fcec01 update supplied the identical App Automation switch fix plus a UI-test
footer assertion. Fast-forwarded to preserve it; publish only the remaining history fix and regression.

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-global-order-final2.xcresult -only-testing:FoundationEvalsTests/EvaluationDevelopmentWorkflowTests/savedRunsKeepGlobalOrderAcrossSuitesAfterRestartAndClockRollback -only-testing:FoundationEvalsTests/EvaluationStoreRunLifecycleTests -only-testing:FoundationEvalsTests/WorkspacePresentationTests test
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-global-order-workflow.xcresult -only-testing:FoundationEvalsTests/EvaluationDevelopmentWorkflowTests test-without-building
```

Extended the restart regression to create an interrupted snapshot in the first suite and an
interrupted active run in the second. Both recover above the last saved sequence, and active-run
recovery advances past snapshot recovery. Final native rerun passed all 72 development-workflow
tests, including this expanded regression. The additional FoundationEvalsTests filter selected no
separate suite; report only the 72 tests that actually executed. No further fixes are required by
these focused checks. Hosted native/UI qualification follows the push.

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-pr131-native-derived -clonedSourcePackagesDirPath /private/tmp/intents-ui-pr-derived/SourcePackages -jobs 2 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-pr131-global-recovery.xcresult -only-testing:FoundationEvalsTests/EvaluationDevelopmentWorkflowTests -only-testing:FoundationEvalsTests/FoundationEvalsTests test
```
