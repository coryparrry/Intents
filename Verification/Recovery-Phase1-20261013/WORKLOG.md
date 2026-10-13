# Phase 1 worklog

- Scope: Phase 1 only, separate PR from current main; retain amended plan and brief.
- PR 135 was already merged at 2026-10-13 16:55:32 UTC before this work. Main base: f03d36497. No release authorized.
- Start with item 6 failing regression using current host templates, then repair codec checks, metadata parsing, persisted preparation and Xcode selection.
- Acceptance: regression green and CLI/probe using shared app capability path, mixed DuplicateTasks UI + intent + query with Xcode 27.0 and 27.2 beta 2. Raw logs/profiles stay in /private/tmp.
- Independent reviewer required after stable diff; report route, location, CI versus local and PR status.

- Item 6 red verified before codec implementation: direct core XCTest executed one test and failed in AutomationCodecRequirements.swift with missingEvidence("Input and result conversion has not been verified for this app and target"). Generated current templates include UIStepTests.swift; supplied capability profile is empty. Unrelated Xcode 27.0 Mac AppIntentsTesting discovery mismatch avoided by isolated core test target.
- Independent scoped review approved implementation with no material findings; runtime acceptance remained pending.
- Xcode 27.0 real fixture preparation succeeded after the first scanner compile timed out under competing compilation. Current template digest differs from the old allowed fingerprints. Probe profiles contain no capabilities.
- Focused codec/physical tests: 18 tests, 2 optional live skips, 0 failures. Final combined checks still pending; concurrency fixture updated to retain its original assertions with valid prepared files.
- Core final recheck: 1,084 tests, 33 opt-in skips, zero failures. Native-wide check found restoration callback/reset regression and stale retained-file fixtures; repaired and independently reviewed, native recheck in progress.
- Xcode 27.0 mixed CLI probe passed via shared app capabilities without supplied records: UI create → CompleteTaskIntent → independent query false→true on same entity. All four receipts completed and resources released; simulator shutdown completed. This is local simulator evidence, not hosted CI or an iPhone/Intent Lab run.
- First real run stopped before dispatch after 15-second simulator inspection timeout. Read-only inspection took 12.18 seconds under load; bounded allowance increased to 60 seconds (cleanup remains bounded at 90) and independently reviewed. Existing recovery API reconciled stopped owner/commands after simulator shutdown before retry.
- Native automation recheck passed, including Swift Testing history checks. Restored selection callback and explicit reset behavior are both covered; independent review approved final callback/fixture changes.

- Xcode 27.2 beta 2 preparation passed after warming the settings query. Mixed execution failed before receipts: AppIntentsTesting requires a symbol absent from installed iOS 27.0 runtime. Cleanup/shutdown passed. Apple download attempts for matching iOS 27.2 arm64 and universal both report unavailable. PR 136 stays draft; full interim acceptance is blocked.
- Runtime lookup correction: explicit version 27.2 was unavailable, but the beta Xcode default catalog found iOS 27.2 build 24B5089g. Download is running; retry acceptance on a fresh matching-runtime simulator before closeout.
- Hosted source checks passed, including settings/relaunch UI and ten picker iterations. Screenshot inspection found filled Xcode fields had no visible labels. Added permanent default/session captions and UI assertions; one fix-and-recheck round is in progress.
- Matching iOS 27.2 runtime installed and fresh preparation passed. First cold-runtime attempt timed out during subject install, before intent dispatch; automatic shutdown and empty campaign ownership were verified. Retrying unchanged on warmed runtime.
- Required local acceptance is complete: Xcode 27.2 beta 2 on matching iOS 27.2 passed all four mixed-workflow receipts, same entity false→true, resource release, empty campaigns and shutdown. Xcode 27.0 deliberate wrong expectation produced assessed assertionFailed with complete independent evidence and cleanup. No capabilities supplied.
- Final caption screenshot recheck and final CI results are tracked in PR 136; the plan, brief and phase evidence are committed. No merge/release or physical-device/Intent Lab execution is authorized in this phase.
- Final-head CI settings/default/override/relaunch test passed and screenshot labels were readable. One existing Siri form test failed because the added caption rows pushed its checkbox below the visible area (click frame was infinite). Changed to inline LabeledContent rows to keep field height; second visual fix-and-recheck round follows. No physical Siri run was attempted.
