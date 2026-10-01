# PR simplification worklog — 30 September 2026

## Scope

Implement D1–D11 and R1–R15 from the supplied review while preserving behavior. Evaluate C1–C2 only with the requested interaction/build evidence. Preserve live legacy integration, public SDK contracts, trust checks, persistence formats, cancellation, and UI presentation.

## Baseline

- Reviewed and current PR #62 head: `e480cc83e445adce3845bbad7d76c5e6152c6d1b`.
- Cleanup branch: `codex/pr-simplification-cleanups`.
- Isolated worktree: `/private/tmp/intents-pr-simplification`.
- Primary checkout remains on `cursor/macos-ui-redesign-341e` with its existing dirty work untouched.
- D1–D11 and R1–R15 implemented with scoped regression coverage.

## Work lanes

- Host evidence/seals/qualification: D2, R1–R3.
- Host run state: D3, D7, R9.
- Core/legacy/Tasks runner: D4 (Siri), D5, D8–D9, D11, C1 evaluation; cleanup-failure fixture prerequisite.
- Testing adapters/invocation: D1, R4–R5.
- Installer/project parsing: D10, R8, R10–R11; C2 evaluation.
- Executor/discovery: D4 (host), R6–R7, R12.
- Main-thread UI: D6, R13–R15.

## Verification plan

Collect focused regression tests, review the stable scoped diff independently, run package and affected host/UI-test compilation with one build owner, inspect affected real UI flows, and record any unverified conditional work. Avoid overlapping heavy builds.

## Current evidence

- Package source/test compilation passes after correcting two new Swift compile errors (closure capture and test exclusivity).
- Affected portable suites: **115 tests in 5 suites passed**. The combined command exits 1 because the unrelated Testing bundle cannot load AppIntentsTesting on this host (missing AppIntentsServices symbol, also recorded by earlier reliability validation). This is a host framework mismatch, not a pass for the combined command.
- C1 **deferred; no C1 source/helper changes remain**. Its synthetic lifecycle matrix passed 2 tests, but independent SDK review correctly distinguished this from actual engine/fencing/checkpoint interaction proof. Existing Tasks declarations lack Feature controls and timeout cases require isolated processes. That proof would need broader fixture/process infrastructure or production test seams. Investigation logs are not final-source verification.
- C2 package iOS tests and legacy `build-for-testing` pass. Both linked test binaries contain exactly one `_IntentLabActivateSiri` symbol. The legacy target imports the canonical package header/source; exception filtering and unsupported-platform behavior are unchanged.
- Independent host review found no cleanup-induced defect. Paired-client interactions for the two R9 entry points remain unverified; helper projection coverage does not establish cancellation/rethrow/teardown through a live connected client.
- Independent SDK review found no cleanup-induced defects in the retained changes.
- Final host behavior suites: **91 tests in 4 suites passed**; all changed app and UI-test sources compile. Both Mac UI attempts failed before executing selected tests: “The test runner hung before establishing connection,” including the ad hoc signed retry. Editor and saved-report screen checks remain unverified. Added self-contained saved-report fixtures and a compiled UI regression test; removed the unsupported blank scroll-view image-render test.
- Main-thread chart inspection: light and dark native SwiftUI renders both show the expected scored/unscored handling, label, and zero-rate point.
- SDK bounded-adapter tests: **6 tests passed on iOS 27** in a temporary SDK-only test package using the exact local sources/tests.
- Signed Tasks framework verification: **4 tests passed** (the three new invocation/readiness tests and the existing Basic Direct check). The earlier unsigned run could not invoke the app; the signed retry resolves that failure.
- Signed Tasks cleanup/context regressions: **5 tests passed**, covering cleanup failure, current/nonempty completion receipts, consecutive preparation contexts, persistent mutation, and suppressed persistence.
- Final package `swift build --build-tests --jobs 2` passes. Direct Core bundle execution with `xcrun xctest .build/out/Products/Debug/IntentLabCoreTestingTests.xctest`: **32 tests passed** after removing the C1 candidate.
- Final `git diff --check`, CI YAML parse, and saved-report fixture JSON/path checks pass.
- Verification completed 1 October 2026. The simulator used for this work is shut down before delivery; the user's preexisting Intents app is preserved.

## Delivery

All 26 required groups and C2 are implemented on the isolated cleanup branch. C1 remains deferred. No change to the dirty primary source checkout, public SDK contracts, persisted versions, or UI layout is intended. Generated logs/builds are excluded from the commit.

Remaining limitations: the aggregate SwiftPM test command is not green because of the host framework load failure; Mac editor/report UI automation could not start after two attempts; the two R9 live paired-client entry points were not rerun end to end. Focused passing suites and source review do not erase those limits.

## CI repair — 1 October 2026

- PR #63 run `36792202517`: portable regressions pass; script checks fail because `ExecutorSimplificationTests` was not added to the route catalog; the native job fails in the new report UI test because assertion rows are inside a collapsed disclosure group.
- Inspected the failing CI screen recording and accessibility hierarchy. The individual fixture loads correctly, with the App action section collapsed; this is a test-navigation error.
- Added the executor suite to its production dependency route and regression coverage for both executor-source and test-file selection.
- The report UI test now expands the correct individual/coordinated lane before checking row content and order. Existing screen behavior and assertions are retained.
- `python3 -m unittest -v script.tests.test_ci_routes script.tests.test_ci_run_tests`: **37 tests passed**, including catalog completeness and executor source/test-file routing.
- Focused `xcodebuild build-for-testing` for `SimplificationUITests` passes; `git diff --check` passes.
- Hosted CI rerun and inspection of both saved-report screenshots remain pending.
