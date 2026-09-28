# Developer workflow remediation: plan and acceptance ledger

Source specification: `Intents_Developer_Workflow_Remediation_Spec_v1.0.md` (2026-09-28). This ledger records implementation and verification, not claims made by the specification.

## Starting point

- Isolated implementation base: `6b74b7ce6f1532e7b031fdc719f17ac05c5ed811` (PR #55), descended from #54 `3cabae9`, #52 `7cc105d`, and #51 `ee9a07d`. PRs #51, #52, #54 and #55 were open on 2026-09-28; #47 was merged.
- The primary checkout has unrelated uncommitted work and is not used for this implementation.
- Installed toolchain: Xcode 27.0 (`27A266a`); record exact test toolchains and source commits with results below.

## Implementation plan

1. **M1:** Freeze reusable requirements separately from execution evidence and profile; add canonical contract hashing, typed comparison, legacy preservation and a before/after regression.
2. **M2:** Add an awaitable snapshot runner and one leased, durable plan across selected routes. Negotiate oracle-free inputs, bind build/fixture/sample identities, and retain failed, cancelled and late evidence.
3. **M3:** Use the compiled declaration for action and feature choice. Make one expectation edit update its observation, projection, claim and assertion together; connect setup and capability guidance to the built UI.
4. **M4:** Complete the production Notes summary integration, retain Tasks controls, and add durable collections and honest full/partial reruns. Capture an unchanged-contract fix/retest record.
5. **M5:** Extract the minimum shared report policy and ship a bounded, offline evidence bundle checker with external trusted requirements. Exercise documented controls and commands.
6. **M6:** Qualify the exact source on available native paths and prepare the independent existing-app exercise; record unavailable hardware or human checks separately.

Each milestone gets focused regressions, integrated validation, a scoped review and a dependent PR. Do not mark an ID passed from a build alone or from an earlier source revision.

## Acceptance IDs

Status key: **Automated pass** = the specified property passed a repeatable test; **Partial** = implemented but some required integration or runtime observation is still missing; **Blocked** = an external resource is unavailable. These are engineering statuses, not a claim of physical-device or independent-human qualification. No ID is implicitly passed by related work.

| Milestone | IDs | Current status and remaining evidence |
|---|---|---|
| M1 | ID-01, ID-02, ID-03, ID-04, CO-01 | Automated pass at #56 and its green CI; clean legacy decode and changed-requirement regressions. No live changed-app run is claimed. |
| M2 | EX-01, EX-02 | Partial: frozen per-coordinate execution and mapping tests pass; a live combined feature/Intent/Siri run is unavailable. |
| M2 | EX-03, EX-04 | Automated pass: 39-test affected native run includes frozen selection and both orders of competing execution admission. |
| M2 | EX-05, EX-06, EX-07, EX-08, EX-09, EX-10, SR-02 | Partial: source and focused failure/contract regressions pass; exact external build, interrupted-app recovery and real Siri outcome have not all been observed live. |
| M3 | UX-01 | Automated pass: atomic expectation authoring and edit regressions. |
| M3 | UX-02, UX-03, UX-04, UX-05 | Partial: built guided setup and missing-support controls were visually inspected; final UI test, relaunch/revocation, narrow/VoiceOver and both-appearance checks remain. |
| M4 | AI-01, AI-02, AI-03 | Partial: production SummaryService wiring and negative controls are implemented; an actual supported-model run with the Notes app has not yet qualified. |
| M4 | AI-04, AI-05 | Automated pass: immutable saved reassessment and unchanged-state baseline regressions. |
| M4 | SR-01 | Blocked: the only connected physical iPhone reports unavailable; run exact Siri phrases and approved alternatives on an available device. |
| M4 | BA-01, BA-02, BA-03, BA-04 | Automated pass: collection membership, full/partial manifest and anti-borrowing regressions. A live multi-case collection remains unverified. |
| M5 | CI-01, CI-02 | Partial: GUI and checker share the qualification core, and the portable CLI runs independently; a saved real-route bundle has not been checked through both surfaces. |
| M5 | CI-03, CI-04, CI-05 | Automated pass: negative bundle and trusted-input regressions, including required repeat and source/observer tampering. |
| M5 | CO-02 | Partial: the published core revision built in a clean external SwiftPM consumer; final release checker archive and installed command still need an exact-source run. |
| M6 | SE-01 | Partial: source guards and debug/release separation reviewed; exact clean release artifact inspection is still needed. |
| M6 | AD-01 | Blocked: no unfamiliar developer, eligible FlipBook test account or available physical device; use the prepared exercise and record all help/interventions. |

## Evidence and decisions

| Date/source | Milestone or ID | Evidence, result, limitation |
|---|---|---|
| 2026-09-28 / `6b74b7c` | Baseline | Read the complete specification and inspected the PR stack and clean isolated worktree. No remediation acceptance passed. |
| 2026-09-28 / installed Xcode 27.0 | API boundary | `IntentDefinitions` supports known-ID lookup, not arbitrary enumeration. Siri activation accepts recognised text; it is not outcome evidence. Foundation Models transcript content is version-dependent. Keep these limits in declarations and reports. |
| 2026-09-28 / uncommitted overlay | M1 | Stable v3 contract and typed comparison added. Focused portable test runs: 59/59 before review fixes and 3/3 after. Reviewer found unverified fixture and measurement implementation identity; these remain open. No integrated runtime qualification yet. |
| 2026-09-28 / uncommitted overlay | M2 | Subject-input package tests 18/18 and snapshot store native tests 7/7 passed at their then-current overlays. Final integrated source remains unverified. A native bridge test host hung before any focused assertions executed. |
| 2026-09-28 / uncommitted overlay | M3 | Guided declaration-backed editor source parses; native app build was stopped while compiling dependencies in a fresh cache. No rendered UI claim yet. |
| 2026-09-28 / `9802bf4` | M1 delivery | Stable contract, typed comparison and regressions committed in draft PR #56 on top of #55. GitHub later reported failed hosted checks; cause not yet established. The PR is reviewable but not green. |
| 2026-09-28 / uncommitted M2–M5 overlay | Focused checks | Contract package 16/16; M4 collection 5/5; M5 bundle 6/6 at then-current overlays. Native bridge test host hung before assertions, and low-parallelism native compile hit Clang dependency scanning before Swift diagnostics. Final overlay requires reruns. |
| 2026-09-28 / uncommitted overlay | M2 independent review | Found mutable runner selection during frozen execution, missing stable subject-input and native environment identities, feature-version-sensitive interface hashing, rename-sensitive suite revisions, continuation after uncertain feature failure, and save-only retry gap. Owners are repairing these; none are accepted solely from source edits. |
| 2026-09-28 / uncommitted overlay | M3–M5 integration | Guided App Feature response checks, record-first result comparison/export, and collection controls are connected in source. Swift parsing and `git diff --check` pass; actual app compilation, controls and user flow remain unverified. |
| 2026-09-28 / uncommitted overlay | Native build limit | Focused `ScenarioIndependentAssessmentTests` did not execute. Xcode exited 65 in dependency scanning, reporting unresolved `FoundationEvalsDeveloper` at the new guided editor import. Conditional package import was added afterward; a fresh build is required. |
| 2026-09-28 / `833ccaf` | M1 CI | Draft PR #56 passed CI run 36440089763, including portable and native app/UI jobs. Local portable full suite passed 150 tests at this revision. Dependent branch must incorporate this fix before PR. |
| 2026-09-28 / uncommitted M2–M5 overlay | Native app compile | Cached Xcode 27 macOS app build succeeded after report and coordinator integration (`/tmp/intents-remediation-native-build-final2.log`). This verifies compilation only; it is not an executed run or visual check. |
| 2026-09-28 / uncommitted M2–M5 overlay | M4 and M5 focused tests | M4 portable `ScenarioContractsTests` 62/62 passed. M5 bundle 15/15 and comparator 7/7 passed before independent trust findings. Native focused tests are being rerun after test-only import/macro fixes. No final acceptance status yet. |
| 2026-09-28 / uncommitted M2–M5 overlay | Independent M5 review | Found five material trust/qualification cases: omitted required repetitions, all-optional or incomparable exit 0, unbound feature input, altered projected feature observations, and partial baseline qualification. Fixes and red/green regressions are in progress; earlier M5 green runs do not qualify the final checker. |
| 2026-09-28 / uncommitted M2–M5 overlay | M5 review fixes | All five cases reproduced as failing regressions, then repaired. Focused `IntentEvidenceBundleTests` 19/19 passed at the later overlay; final package and native checks remain pending. |
| 2026-09-28 / uncommitted M2–M5 overlay | M2 native execution | After isolating test credentials from the developer Keychain, cached Xcode macOS `ScenarioExecutionPlanTests` executed 9/9 passed. Other native suites are still in progress. |
| 2026-09-28 / local hardware | SR-01, AD-01 limitation | `xcrun devicectl list devices` showed the only connected physical iPhone as `unavailable`; simulators were shutdown. A physical Siri result and unfamiliar-human exercise cannot be claimed from source or simulator evidence. |
| 2026-09-28 / `833ccaf` | M1 final | PR #56 CI run 36440089763 passed all reported jobs. Its 150 portable tests and changed-contract/legacy regressions establish the M1 automated layer. |
| 2026-09-28 / `492ec87` plus M1 merge `725a815` | M2–M5 core | Full SwiftPM run passed 187 portable tests and 18 developer protocol tests. Four affected native suites passed 39 tests, including final admission and v3 bridge fixes. Existing CLI regression tests passed 2/2. These tests ran against the same source overlay immediately before the core commit; the merge adds only the green M1 regression test. |
| 2026-09-28 / published `725a815` | CO-02 package consumer | A separate `/tmp` Swift package resolved `https://github.com/coryparrry/Intents.git` at the exact commit and built `IntentLabTesting` and `IntentLabContracts` without local path rewrites. The first probe used macOS 14 and correctly failed the package's macOS 26 minimum; the corrected macOS 26 consumer built successfully. This is package resolution, not native app installation. |
| 2026-09-28 / precommit UI overlay | M3 visual inspection | Launched the built macOS app with isolated storage. Inspected Connect/setup, Create developer check, declaration support guidance, Assertions, Collections, and Results empty states in the real interface. Corrected stale Results copy and rebuilt. A saved result/retest screen could not be reached without a connected subject app. Closed the app afterward. |
| 2026-09-28 / precommit UI overlay | UX-02 UI test attempt | Xcode rebuilt the macOS app and UI test target, then the UI runner remained at `_dyld_start` for over four minutes without starting a test method. It was stopped and its app/runner processes exited. This is not a passing UI test; the same missing-support path was inspected manually in the built app. |
| 2026-09-28 / precommit UI overlay | Native and package rerun | Final UI/installer source passed 188 portable tests plus 18 developer protocol tests. The affected macOS installer, collection, assessment and no-mutation suites passed 47/47. The macOS UI test target built but did not execute because of the runner stall above. |
| 2026-09-28 / precommit Notes overlay | M4 iOS simulator | `IntentLabFixtureV2UITests/IntentLabQueryObserverTests` compiled and executed 9 tests: 7 passed, 2 entity-query tests failed. `IntentDefinitions` produced `AppIntentsServicesSecurityErrorDomain` code 803, “Unable to run internal tests on a Customer build”; the negative test then failed its expected error-type assertion. The prepared app had no fabricated summary, the combined subject feature was advertised, and stale/wrong-source completion checks passed. The simulator was confirmed Shutdown afterward. This does not qualify a real model summary or Siri result. |
| 2026-09-28 / precommit Tasks overlay | M4 iOS simulator | The first `IntentLabRunnerFaultTests` attempt used Debug instead of the scheme's `IntentLabTesting` configuration, so its six tests could not launch the integration-test bundle. The corrected configuration executed six tests but all retained `invalidEvidence`/`notObserved`, not the expected app outcomes. Exported XCTest evidence identifies “Unable to run internal tests on a Customer build”; no production persistence or no-mutation result was qualified. The simulator was confirmed Shutdown. The portable no-mutation regression and 47 native app tests still pass. |
| 2026-09-28 / precommit UI overlay | Independent UI review | Found stale global runner selection hiding the sole app runner, guided authoring of declared date/enum/entity/array values failing validation, and shared create/partial-run toggle state. The UI and coordinator now choose the sole matching runner while retaining strict frozen-runner identity, edit declared value types, and keep run scope independent of creation/membership. A first focused native compile found a Swift contextual enum inference error; repaired it and reran 15/15 native tests in the affected plan/authoring suites. The collection toggle state has source/compile verification but no UI runner result. |
| 2026-09-28 / precommit UI overlay | Final portable review rerun | After moving shared runner-selection and typed-default logic into portable sources, the full SwiftPM run passed 190 app tests and 18 developer protocol tests. The same UI implementation had already built and executed 15/15 focused native plan/authoring tests before that source-only move. |

## Worklog

- 2026-09-28: Began M1 on `codex/developer-workflow-m1`, based on PR #55. Primary checkout remains untouched.
- 2026-09-28: Kept M2 native route execution, subject bridge and snapshot store in independent owned files; connected the declaration-backed M3 editor in the main agent. Composite M2 result will use the frozen execution record and immutable child runs, avoiding a false single-invocation identity.
- 2026-09-28: Began independent M4 Notes controls, collections and M5 offline checker while native integration continues. These are implementation work in progress, not acceptance evidence.
- 2026-09-28: Committed M1 as `9802bf4`, opened draft PR #56 against #55, and continued the shared worktree on dependent `codex/developer-workflow-m2`.
- 2026-09-28: Independent M2 review identified three integration defects under repair: missing stable feature-input digest, rename-sensitive internal suite revision, and missing observed native environment identity. Native wrong-source handling also needed to retain a business failure rather than reclassify it as invalid evidence.
- 2026-09-28: Added guided `feature.response` checks so captured AI output cannot pass without an explicit requirement. Added collection creation/full/selected/rerun controls and reviewed same-outcome variations. Assessment overlays and batch export still need integration and final verification.
- 2026-09-28: Connected saved semantic assessment selection and consent in Results, batch export in Collections, and the report's durable qualification path. Updated the developer guide to use the built labels. One cached app build passed; native tests and visual inspection remain in progress.
- 2026-09-28: Independent core review found asymmetric ordinary/scenario run admission and optional-route checker/report mismatch. Both were reproduced in regressions, fixed, and rerun. Committed the core as `492ec87`, merged the green M1 fix as `725a815`, and opened dependent draft PR #57.
- 2026-09-28: Verified the published core package revision through a clean external consumer and pinned that SHA for the guided installer. The UI/example PR remains in progress.
