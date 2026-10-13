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
