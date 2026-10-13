# Phase 1 verification — 2026-10-13

Phase 1 of the amended recovery plan. Changes are in this PR, not merged or released. PR 135 had already merged before this work; this PR starts from main at `f03d36497`.

Typed plans now use the conversions implemented by the saved host after checking its generated sources, subject, host and test-run file. The app and CLI probe share base capabilities and execution resolution; profiles containing capabilities are rejected. Preparation can restore after relaunch. Metadata version 1 stays visible on unfamiliar Xcode builds, and Xcode defaults persist separately for simulator, device and Mac with a session override and device/Mac SDK preflight.

## Verified locally

- Item 6 first failed in `PlanValidator` with `missingEvidence`, before the codec fix. Its generated host includes current `UIStepTests.swift`; the products are synthetic unit fixtures and the supplied capability profile is empty. The same regression now passes.
- Core automation: `swift build --jobs 2 --product IntentsAutomationCoreTests`, then `xcrun xctest .build/out/Products/Debug/IntentsAutomationCoreTests.xctest`: 1,084 tests, 33 optional live skips, zero failures.
- Native automation: equivalent build and direct XCTest commands for `IntentsAutomationNativeUITests`: 163 XCTest tests plus two Swift Testing checks, zero failures.
- CLI probe, **iOS simulator on this Mac**, Xcode **27.0**: UI create → `CompleteTaskIntent` → independent query passed without supplied capabilities. One entity changed from incomplete to complete; all four receipts completed, resources released and the simulator shut down. This used the app's shared capability code; it was not a desktop app or Intent Lab run.
- The probe rejects a profile containing capabilities before execution. Independent scoped reviews found no material issues. CI YAML parses.

## Pending before acceptance

- Xcode 27.2 beta 2 preparation and the same mixed simulator workflow.
- Native Debug app Xcode-settings UI test and visual screenshot inspection.
- Hosted PR checks. The Phase 3 simulator workflow CI job does not exist yet; the live workflow above is local evidence.

The first real workflow stopped before dispatch at a 15-second simulator inspection timeout. After observing a 12-second read-only inspection under load, the bounded allowance became 60 seconds; all checks remain, and cleanup remains bounded at 90 seconds. The stopped campaign was recovered through the existing API after owner/command exit checks and simulator shutdown. The retry passed. A cold Xcode 27.2 source-scanner compile exceeded 120 seconds; its bounded allowance became 300 seconds, with cancellation and checks retained.

The optional conversion diagnostic preserves the existing **Mac-only** canary and never grants or revokes execution capabilities. No live diagnostic, iPhone, Mac intent/UI workflow, or Intent Lab run was performed in this phase. Every codec family's real echo is still Phase 3 acceptance.

Raw logs, profiles, prepared products and screenshots stay outside git in the temporary verification directory. Only this README, the compact worklog, plan and brief are committed.
