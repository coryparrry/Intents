# Workspace UI PR

## Scope
Finish the existing workspace redesign, preserve tab motion, and make Performance and Review & release peer tabs beside Report and Workflow trace.

## Isolation
- PR branch starts from main at b17cb767d.
- Includes UI, presentation logic, and focused tests only.
- Preserves main’s Evaluations, Batch runs, Traces, suite Review/Compare, Intent Lab Collections, and diagnostic controls.
- Unrelated local automation, Siri, telemetry, and website work remains outside this PR.

## Verification
- Read-only independent source review: no remaining actionable findings.
- Fresh build-for-testing passed.
- Final focused run: 17 presentation tests and 7 UI tests passed, zero failures.
- Native screenshots inspected at 1,000 points: all five suite tabs, run controls, Add Case, Performance, and Review & release fit. Synthetic fixture screenshots are retained in PR-Screenshots.
- Initial runs exposed two missing test dependencies during isolation: explicit Workflow trace selection and DEBUG window sizing. Both were restored. Tests now assert actual minimum width.
- Final source review and git diff checks passed. The test app was confirmed closed; no simulator was used.
- No continuous recording established animation smoothness.

## Commands

```sh
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-ui-pr-derived -jobs 4 -parallel-testing-enabled NO build-for-testing
xcodebuild -project FoundationEvals/FoundationEvals.xcodeproj -scheme FoundationEvals -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/intents-ui-pr-derived -jobs 4 -parallel-testing-enabled NO -resultBundlePath /private/tmp/intents-ui-pr-final.xcresult -only-testing:FoundationEvalsTests/WorkspacePresentationTests -only-testing:FoundationEvalsUITests/WorkflowTraceUITests/testNavigationKeepsControlsVisibleAtMinimumWidth -only-testing:FoundationEvalsUITests/WorkflowTraceUITests/testReportKeepsAdvancedToolsInDedicatedTabs -only-testing:FoundationEvalsUITests/WorkflowTraceUITests/testPerformanceChartsShowUnitsScoreGuideAndPercentagePoints -only-testing:FoundationEvalsUITests/WorkspacePolishUITests -only-testing:FoundationEvalsUITests/FoundationEvalsUITests/testCaseSelectionSurvivesSetupNavigation -only-testing:FoundationEvalsUITests/FoundationEvalsUITests/testCaseSearchKeepsEditorAndScoringSelectionAligned test
git diff --check
git diff --cached --check
```
