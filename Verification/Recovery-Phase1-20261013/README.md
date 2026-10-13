# Phase 1 verification — 2026-10-13

Phase 1 of the amended recovery plan. Changes are in this PR, not merged or released. PR 135 had already merged before this work; this PR starts from main at `f03d36497`.

Typed plans now use the conversions implemented by the saved host after checking its generated sources, subject, host and test-run file. The app and CLI probe share base capabilities and execution resolution; profiles containing capabilities are rejected. Preparation can restore after relaunch. Metadata version 1 stays visible on unfamiliar Xcode builds, and Xcode defaults persist separately for simulator, device and Mac with a session override and device/Mac SDK preflight.

## Verified locally

- Item 6 first failed in `PlanValidator` with `missingEvidence`, before the codec fix. Its generated host includes current `UIStepTests.swift`; the products are synthetic unit fixtures and the supplied capability profile is empty. The same regression now passes.
- Core automation: `swift build --jobs 2 --product IntentsAutomationCoreTests`, then `xcrun xctest .build/out/Products/Debug/IntentsAutomationCoreTests.xctest`: 1,084 tests, 33 optional live skips, zero failures.
- Native automation: equivalent build and direct XCTest commands for `IntentsAutomationNativeUITests`: 163 XCTest tests plus two Swift Testing checks, zero failures.
- CLI probe, **iOS simulator on this Mac**, Xcode **27.0**: UI create → `CompleteTaskIntent` → independent query passed without supplied capabilities. One entity changed from incomplete to complete; all four receipts completed, resources released and the simulator shut down. This used the app's shared capability code; it was not a desktop app or Intent Lab run.
- The probe rejects a profile containing capabilities before execution. Independent scoped reviews found no material issues. CI YAML parses.

## Simulator acceptance and CI

- CLI probe, **iOS simulator on this Mac**, Xcode **27.2 beta 2** with matching iOS **27.2 (24B5089g)**: the same UI create → intent → independent query passed with no supplied capabilities. One entity changed from incomplete to complete; all four receipts completed, resources released, campaign ownership cleared and simulator shutdown completed.
- Xcode 27.0 deliberate wrong expectation: `assertionFailed`, with the intent completed, independent query evidence complete and resources released. This also used shared app capability resolution without supplied capabilities.
- [Initial hosted CI](https://github.com/coryparrry/Intents/actions/runs/38449864414) passed portable regressions, the native Debug app settings/relaunch UI test and ten preparation-picker repetitions. Its actual settings screenshot was inspected. Filled fields lacked visible labels, so permanent default/session captions and two assertions were added. The final caption screenshot and final checks are tracked in [PR 136](https://github.com/coryparrry/Intents/pull/136).
- The Phase 3 live simulator workflow CI job does not exist yet. The two mixed workflows ran locally; CI covers regressions and Mac app configuration UI.

The first real workflow stopped before dispatch at a 15-second simulator inspection timeout. After observing a 12-second read-only inspection under load, the bounded allowance became 60 seconds; all checks remain, and cleanup remains bounded at 90 seconds. The stopped campaign was recovered through the existing API after owner/command exit checks and simulator shutdown. The retry passed. The first Xcode 27.2 preparation timeout occurred after source-scanner inputs were written; the bounded cold-compile allowance became 300 seconds, with cancellation and checks retained. A later attempt timed out earlier at build settings. The same settings query succeeded directly and through the owned command API; a subsequent preparation passed.

Xcode 27.2 initially failed to load Apple’s test framework on iOS 27.0 because that runtime lacks `PropertyContainerElement.valueExpression`. Explicit-version download queries returned unavailable; the beta Xcode default catalog found and installed the matching iOS 27.2 runtime. Its first cold boot timed out during subject installation, before dispatch; automatic shutdown and empty ownership were verified. The unchanged retry passed. These retries are local tooling evidence, not a claim that cold-runtime startup is always reliable.

The optional conversion diagnostic preserves the existing **Mac-only** canary and never grants or revokes execution capabilities. No live diagnostic, iPhone, Mac subject intent/UI workflow, or Intent Lab run was performed in this phase. Every codec family's real echo is still Phase 3 acceptance.

Raw logs, profiles, prepared products and screenshots stay outside git in the temporary verification directory. Only this README, the compact worklog, plan and brief are committed.

## Conditional merge review

PR 136 review found and repaired three issues. Intact hosts now verify against their own saved source inventory; changed files and unsafe paths still fail. A failed or cancelled input diagnostic exposes recovery for its exact campaign without permitting reset of other live runs. A corrupt newest completed preparation now asks the user to prepare again instead of silently restoring an older app or target. Core and native regressions cover these cases, and independent scoped source reviews found no material blockers. The device/Mac SDK major/minor check follows the amended plan and remains.

After the review fixes, direct core XCTest passed 1,087 tests with 33 optional live skips and zero failures. Native direct XCTest passed 170 tests plus two Swift Testing checks, with zero failures; the updated PR checks must be green before merge. These regressions ran on this Mac and do not add iPhone, Mac subject or Intent Lab execution evidence.
