# Phase 2 acceptance on current main

The in-host UI workflow and sidecar removal are complete. The change is isolated from unrelated unpublished local work and preserves current main's prepared-artifact, recovery, and release contracts.

## Acceptance evidence

Both disposable simulator profiles passed on the mixed-workflow source revision `57b218b63` using the 14 host templates bundled in the ad hoc Intents Debug app. The final Debug build succeeds with an empty Team ID; strict deep signature verification passes and no sealed sidecar is bundled.

- Cold-start mixed workflow: UI creates a uniquely scoped task, a query reports it incomplete, `CompleteTaskIntent` completes that entity, and an independent query reports the same entity complete. All five segment receipts complete in one Xcode invocation. The saved report is passed, assessed, and evidence-complete.
- Deliberate raw UI assertion failure: the saved report retains the terminal scoped receipt and screenshot. It remains unassessed with incomplete evidence and cannot grant positive fixture authority. The single Xcode invocation and resource cleanup are verified.
- Both runs complete boot, readiness, installation, and shutdown with exit status zero. The task simulator ends shut down and no campaign reservation remains. Both captured screenshots were inspected.

## Regression verification

- Relevant Core, native workflow, host-contract, Intent Lab core, and Intent Lab contract XCTest bundles: 1,337 cases, 33 opt-in skips, zero failures.
- Portable Swift Testing: 353 tests pass. The unchanged local `IntentLabTestingTests` bundle cannot load because the installed system framework lacks a symbol required by Xcode's `AppIntentsTesting`; hosted CI must verify that gate.
- Final preparation diagnostics and boot ownership regressions: 7 tests pass after the last source changes. These cover scoped log capture, early cancellation, private permissions, bounds, process/drain proof, and retention of the root reservation.
- Script regressions: 87 tests pass. ShellCheck, shell parsing, and scoped whitespace checks pass.
- The later Apple-runner cleanup refinement passed all 31 affected route tests, including the reproduced CI failure and transient/persistent unknown-state cases. It preserves the mixed XCUITest route.
- Independent source reviews have no outstanding material findings, including the cleanup refinement.

Physical-device and native Mac UI execution, signed distribution, and release qualification remain outside this Phase 2 acceptance.
