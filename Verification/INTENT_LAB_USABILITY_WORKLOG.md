# Intent Lab usability — 2026-09-27

## Outcome
Make connecting an app, creating a test and reading results clear for people who do not know the underlying harness terminology. Collect unambiguous configuration automatically. Preserve project-build approval, explicit project-write review, validation, immutable evidence and device-recovery safeguards.

## Accepted visual baseline
Keep Lucide assets, restrained accent header treatment and existing app surfaces. Main owns every UI edit and screenshot check. Preserve unrelated dirty work.

## Work
- [x] Inspect real existing Setup; installer expands before device choices, long glossary and duplicate configuration overwhelm the workflow.
- [x] Restructure Connect app / Create test / Results with compact setup and progressive technical details.
- [x] Improve safe automatic discovery and add focused regressions.
- [x] Simplify test editor and results wording; preserve capability and honest prerequisites.
- [x] Build, focused coordinator tests, real-flow inspection and independent review completed. Full UI automation remains unverified (limitations below).

## Current decisions
- No silent approval of build scripts or project edits. Discovery may fill a unique choice; ambiguity must remain visible.
- Keep technical data available in expandable details; do not disguise missing test support as a ready connection.
- Save/run controls should be discoverable beside the test, rather than buried in Run settings.

## Verification in progress
- First app build passed; inspected Connect app and Create test in the real app with isolated data.
- Shortened repeated help and moved inputs/checks directly below the request after the first visual inspection.
- Unique app/device selection regressions added; build and focused UI tests next. Independent review running.
- First focused run: 12 coordinator tests passed; basic navigation and unavailable-device UI checks passed. Disclosure-dependent UI checks failed because clicks targeted the row label; CUA confirmed the disclosure action expands correctly. Updated test clicks to use the native disclosure arrow.
- Independent review found no route to create a second reusable test or reopen saved tests. Added a saved-test menu, always-visible New test, and unsaved-draft confirmation. Coordinator restoration and round-trip regressions are being added before final verification.
- Saved-test restore is implemented and independently reviewed. Same-project approval is retained and readiness refreshed; changed projects/targets clear stale connection state. A round-trip coordinator regression passed.
- Second UI run clarified the input failure: the section accessibility identifier propagated over its child field identifiers. Removed that identifier. Expanders now use a whole-row button with an accessible Expanded/Collapsed state; updated tests accordingly. Draft-dialog tests disambiguate Cancel with firstMatch.
- Final focused regression run is in progress at /private/tmp/intents-usability-verified.log. No device action or consumer-project build was run.

## Final verification
- Final app compiled and launched. All 13 IntentLabRegressionTests passed, including saved-test round trips and unique/ambiguous selection.
- Automated basic Intent Lab navigation passed. The wider UI run repeatedly encountered another app’s window and was interrupted; do not claim the entire UI suite passed. Final selectors follow observed native disclosure roles and scope Cancel to its sheet; those final selector edits were not rerun.
- Direct CUA checks on isolated data verified: Connect app → Create test; About App Intents expansion; input expansion with intact accessibility identifiers; adding/removing a parameter; numeric array typing `1,` → `1,2` without losing the draft; Cancel preserving edited input; New test creating v2 while remaining available; Results → Connect app.
- Inspected actual setup/editor/results screenshots. Later captures were partially blank below the visible display region; verified visible sections and accessibility state without claiming a complete final full-window screenshot.
- Independent review found the repeat-test and stale-readiness issues; both were fixed and reviewed again. No consumer app action, consumer project modification, deployment or device eval was performed.
- Verification app closed. `git diff --check` passed. Existing unrelated working-tree changes preserved.

## Follow-up: project selection is the connection flow
- User correctly identified that “Check project” exposes an implementation step with no clear difference from selecting a project.
- Choosing a project now immediately offers the connection approval, which explains automatic settings discovery and session build permission. Removed the separate numbered Check project step.
- A saved project offers Connect app beside its name when session approval is needed; connected projects show status in the same row.
- Pending: build and direct file-selection/approval/cancellation verification on isolated data.
- Follow-up verified: app build passed. Direct UI selection of a disposable `.xcodeproj` opened “Connect this app?” automatically; Cancel retained the chosen project without approval or enabling Run.
- Focused XCTest `IntentLabGuidanceUITests/testChoosingProjectOffersConnectionAndCancelDoesNotApprove` passed. `git diff --check` passed. Preview closed; no project scripts or evaluations were run.

## Follow-up: sidebar Beta label
- Added a small, neutral Beta capsule beside Intent Lab in the sidebar. Kept the existing icon and selection behavior; combined the label for accessibility.
- Pending build and visual check. No behavior changed, so no new regression test is needed.
- Beta label verified in the actual sidebar screenshot and accessibility tree (“Intent Lab, Beta”). Build and diff checks passed. Preview closed.

## Actual device verification
- User requested full end-to-end verification. Physical iPhone available and existing fixture provisioning profiles found; old signing blocker is stale.
- Using a disposable copy of the Notes fixture with local signing team configured, preserving source project and user workspace data.
- Actual UI Run on physical iPhone: v1 positive run CFCDF88B-D056-4CFB-8956-09223FD43E1C passed. Captured selectedNoteID=packing-001 and noteStoreMutationCount=0; both required checks pass, XCTest exit 0; Results inspected.
- Negative control AF88D964-A645-4275-9CFB-F3195F895A51 expected deliberately-wrong-note. Real observed packing-001 was rejected; lane failed, XCTest exit 65, host retained needsReview/invalidEvidence and quarantined device. No false pass.
- Found misleading attribution claiming an unobserved app-feature control passed; backend fix and regressions in progress.
- Found binding an existing v2 declaration retained the previous v1 test bundle ID. Reselecting the discovered v2 target allowed the actual support build; coordinator metadata fix and regression in progress.
- Reusable v2 compiled connection check passed on physical iPhone (1 test, exit 0), receipt stored in Connection-195CAC63-77E9-497A-B696-3EE6894CBA56. A reusable scenario was created and saved using the UI; its action run remains unverified.
- The phone locked again. Asked user to unlock and keep awake; no second reply received during this verification. A dedicated real fixture reset/query readiness test could not bootstrap while locked (exit 65). Device reservation was intentionally not cleared without proof; Siri and v2 action runs remain blocked/unverified.
- Fixed attribution and installed-integration metadata. Added four regressions. Initial host test run stalled reading the user's MCP credential; isolated DEBUG verification launches now use an unavailable credential store and cannot read/write/remove that credential. Normal launches retain Keychain behavior.
- Rebuilt app and all 17 IntentLabRegressionTests passed: /private/tmp/intents-e2e-fixes-tests-isolated.log. `git diff --check` passed.
- Relaunched actual updated app with isolated storage. Both positive and negative reports survived; actual screenshot/AX confirms corrected negative explanation and preserved passing report. Preview closed. No simulated report was injected, no simulator used, and no consumer project changed.

## Remaining checks retry
- Physical reset/query readiness test passed on retry, exit 0 (/private/tmp/intents-e2e-readiness-retry.log). Cleared quarantine only after the verified reset and app teardown.
- Siri scenario 08B0155D-FF1D-4490-B4F1-AA54293842BE: real physical Siri request and direct action both passed; selectedNoteID=packing-001, mutation count 0, Siri context matched invocation. XCTest exit 0. Reviewed actual Results screen and captured iPhone screenshot. Siri activation diagnostic was retained; correlated final app state and both required assertions passed.
- Reusable run 68BA95BE-C60C-4DDF-A689-A87CD5212918 exposed a real bug: rebuilding after connection verification changes executable UUIDs/generated metadata. Fixed v2 execution to use the exact verified build, retaining identity/input/metadata checks and unique per-invocation xctestrun files. Independently reviewed.
- Reconnect also reset a valid saved v2 scheme to the app-named scheme. Fixed valid scheme preservation and added regression.
- Final validation in progress. Original host build cache had a missing Sparkle artifact/stale cache; recovered same-version local artifact and building into /private/tmp/intents-e2e-host-final.
- Fresh fixed host build succeeded; 18 IntentLabRegressionTests passed (/private/tmp/intents-e2e-final-tests.log). The payload-preservation regression is portable-only and passed separately with `swift test --jobs 2 --filter xctestrunTransportKeepsTestRootAndPreservesXcodeEnvironment` (/private/tmp/intents-e2e-payload-test.log).
- Actual fixed UI reconnect preserved IntentLabFixtureV2. Final connection build Connection-8D1DCB54-CE2F-4352-8BD6-5648C545999E completed, but its on-device receipt test is currently awaiting another unlock. User notified immediately; no further rebuild needed after unlock. Final v2 action result not yet claimed.
- Final reusable run 62A51257-C588-4679-B75C-A3EA95B0C94F passed on the physical iPhone after unlock: execution completed, XCTest exit 0, report persisted. Reused the qualified Connection-8D1DCB54-CE2F-4352-8BD6-5648C545999E build. Actual report screenshot and accessibility state inspected; correctly labels Basic execution coverage and states application state was not checked. Siri was separately verified above. Preview app closed; no simulator used. All remaining requested checks are complete.
