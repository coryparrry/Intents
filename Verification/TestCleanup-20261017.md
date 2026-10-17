# Test cleanup closeout — 2026-10-17

The test cleanup is ready for delivery. The mutation campaign was stopped at the user's request; exhaustive mutation qualification is incomplete.

## Delivered scope

The original cleanup removes duplicate, fixed-mock, configuration-copy, roundtrip-only and otherwise ineffective checks while retaining checks tied to consequential production behavior. Useful coverage restored during review remains in the delivery.

The final mutation-backed edits remove three methods whose assertions were satisfied by unrelated earlier validation, plus one invalid negative subsection inside a retained integration test. Those removals cover two native-evidence alias cases and one Spotlight tool-name collision case. The enclosing integration test and direct provenance checks remain.

Fourteen test setup expressions now honor `DEVELOPER_DIR`, with the existing Xcode installation path as fallback. This lets the selected toolchain run the affected build/parser checks.

No production behavior changes or mutation instrumentation are included.

## Verification before PR integration

The original cleanup recorded passing verification for 352 Python tests, 1,224 XCTest cases (23 existing opt-in cases skipped), 341 Swift Testing cases, 143 plugin Node cases and 25 website cases. These counts include focused restoration checks and permission-sensitive retries; they are not one fresh full-suite run. The native plugin runner also passed its core, app protocol, workflow, revision/summary and process checks.

The final edits have narrower verification:

- `swift build --disable-sandbox --jobs 2 --target IntentsAutomationCoreTests` with an isolated scratch directory passed. All 15 retained `AutomationNativeEvidenceTests` and all four `AutomationSourceSyntaxTests` passed; the real parser check was enabled with `INTENTS_SOURCE_SYNTAX_TEST=1`.
- Native `xcodebuild build-for-testing` for the FoundationEvals scheme, macOS arm64, passed without mutation instrumentation. All 11 remaining Spotlight methods and five additional focused restored controls passed.
- Before rebasing for PR integration, all 631 repository inputs from that native build matched the delivery checkout. The Core diff matched its successful build record; Core log hashes and all 16 native control log/event hashes matched the recorded results.
- `git diff --check` passed for the complete cleanup.

These successful checks qualified the reviewed cleanup before PR integration. No new mutation campaign or broad test run was started at closeout.

## PR integration

The cleanup was initially rebased onto the CI-fix attempts in PR #141. At the user's request, all 21 subsequent CI-fix attempts from both chats were then rolled back to the original feature revision, `df4b97ce7`. PR #141 now adds only the requested Mac UI suite exclusion and CI failure reporting on top of that source.

This cleanup was restacked onto that rollback and CI policy. Conflict resolution preserves the reviewed test removals and the new failure-summary coverage; it does not restore the reverted runtime fixtures or signing/deadline tests. No additional test trimming was performed.

After this restack, `python3 -m unittest script.tests.test_ci_routes script.tests.test_ci_native_tests script.tests.test_ci_workflow script.tests.test_ci_failure_summary` passed all 101 tests. The three Swift files affected by rebase merging passed `xcrun swiftc -frontend -parse`: `AutomationMCPTests.swift`, `NativeHistoryRefreshTests.swift` and `AutomationXCUITestTests.swift`. The diff against the prerequisite branch passed `git diff --check`.

Native builds and runtime checks were not repeated after this rebase. Their results above describe the pre-rebase source; final integration runtime qualification is left to CI.

## Qualification limits

Exhaustive proof that every retained test catches a meaningful defect is unfinished. Completed mutation results coexist with unreviewed results, original baseline failures, unavailable profiles/model resources and runner prerequisites. Useful tests were retained when proof was blocked. No complete-suite mutation score is claimed.

The second native app group still required follow-up review when work stopped. Some Siri, native UI, physical-device and AppIntentsTesting paths remain unqualified; the installed AppIntentsTesting framework had a missing private AppIntentsServices symbol. These limits are not resolved by the focused passing checks above.

Raw audit ledgers, mutation sources, runner products and logs remain local under `/tmp/intents-behavior-audit-20261017` and `/tmp/intents-mutation-proof-20261017`; they are temporary evidence and are not part of the delivered source.
