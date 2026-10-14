# Phase 3 worklog

- Scope: supported CLI, committed all-codec fixture, simulator e2e CI and opt-in fixture UI-test migration; own PR on main after PR 136.
- Base: merged PR 136 at f205bc9ba; reviewed head 10eb7c051 had all hosted checks green. Primary dirty checkout preserved; isolated recovery worktree reused on codex/recovery-phase3-20261013.
- Release PR 130 held; no merge or release for Phase 3.
- Owners: fixture and active fixture paths; CLI/parser/tests; CI/e2e/router/tests; opt-in UI migration. Parent owns docs, plan, serial builds/live runs and final review.
- Acceptance: CLI resolves capabilities with app code, all 16 codec families plus empty arrays exact, assessed mixed workflow, wrong assertion, timeout/release and immediate rerun; relevant hosted simulator job green. No capability records in profiles/plans.
- Native Mac/iPhone/Siri/Intent Lab execution is outside Phase 3 qualification. Optional live Mac setter diagnostic remains Mac-only; simulator codec echoes test the conversion boundary directly.
- After model interruption, recovered partial edits and resumed disjoint CLI/CI/UI owners. No orphaned task processes found. Fixture iOS Simulator and Mac builds passed; model tests running. Independent fixture review found no blockers. Other projects have active tests, so local builds remain serial and bounded.

- Fixture model tests passed (6). CLI product builds. First 12 CLI regressions passed; independent review prompted stronger Mac assembly and wait-only budget coverage before final run. Python routing/e2e driver checks passed (50). Runtime selection now matches the selected SDK major/minor, and SIGTERM drains owned commands and simulator cleanup.
- Independent fixture/opt-in UI and CI/e2e reviews are clean. UI selector fixes use Destination control, Record name entry control and Save control. CLI review fixes are under final verification.
- Final CLI regressions passed: 13 tests, zero failures. Independent CLI recheck is clean. PR 136 post-merge main CI 38471960831 is green. Full one-command local e2e started with owned iOS 27.0 simulator and raw output under /private/tmp/intents-phase3/e2e-local-1; result pending.
- Plan cross-reference audit found the Phase 1 requirement for a live canary in Phase 3 CI. Added a separate Mac setter/readback CI lane using the existing opt-in authored String fixture; this is diagnostic coverage, not Mac business subject qualification or a capability gate.
- First full local command prepared successfully, then exposed a CLI /tmp versus /private/tmp identity mismatch on actions. Fixed by sharing AutomationPath realpath normalization; 14 CLI regressions and 53 Python checks pass. The failed run removed its owned simulator. A second complete run is using the same Swift build cache with a fresh output root and simulator.
- Verified the fixed CLI against the first run's real retained preparation via its /tmp alias: actions returned all 18 captured actions without rebuilding or executing the app.
- Second full run restored the catalog successfully, then stopped before dispatch because FixtureReference had no readable text property. Added a deterministic Name property to the fixture entity, keeping its identifier and query behavior. The complete catalog guard remains in place; simulator cleanup passed.

- Hosted head 212c09 passed the live Mac setter/readback diagnostic, app compilation and portable tests. Simulator preparation passed but the driver misspelled EchoURLIntent; corrected it and made the mock catalog independent. Fixed shellcheck SC2155 in the diagnostic lane. All 53 Python checks pass, and both codec batches validate against the real captured catalog before another live run.

- Local run 4 passed exact comparisons for the first 15 codec families and all five empty arrays. IntentFile producer setup failed with AppIntentsServicesMetadataErrorDomain 400 (fixture bundle not present); raw result retained, owned simulator removed. Investigating the real runtime boundary.
- Two independently validated PR review findings fixed: selected Xcode fallback and testing-only helper scheme entries. All 19 CLI regressions pass, independent recheck is clean, and the current fixture Mac target builds.

- Fixed actual Xcode attachment-name suffix import and ignored automatic recordings as claimed data, retaining exact receipt/digest checks. Added explicit shared host activation from the already-approved navigate effect; missing navigation preserves prior behavior. Independent review is clean; 33 native driver tests, 41 host contract tests and 53 Python tests pass. Full runtime rerun is required to establish the fix.

- Local run 5 proved native IntentFile producer and consumer return the same exact bytes. Report import then exposed Xcode treating the dot in file.echo as an extension. Fixed matching against exact expected attachment names, including the shared diagnostic importer. Dotted-name and ambiguous-name regressions pass: 43 host-contract tests and 53 Mac driver/probe tests, with independent review clean. Owned simulator cleanup passed.

- Local run 6 passed all seven cases on source 1bd8edcd5 (Xcode 27.0/iOS 27.0), including all 16 exact codec families, assessed mixed workflow, wrong assertion, timeout release and immediate rerun. Every saved report matched; campaign state was empty and owned simulator deletion verified. Inspected actual in-test fixture screenshot. Removed redundant launch/screenshot commands that raced startup and produced a blank image; 53 Python checks still pass. Hosted current-head CI remains the final acceptance gate.
