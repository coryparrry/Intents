# Intent Lab physical-device validation — 2026-09-26

## Result

The signed Mac interface successfully discovered the integrated fixture project and paired iPhone, built and signed the app and UI-test target, started the physical-device scenario, imported final evidence, displayed the result, and preserved it across relaunch. A deliberate wrong expectation was correctly reported as **Failed** after the fixes in this change, and could not satisfy the release requirement.

Validation used the combined PR #51/#52 stack, initially at `22d7a6e`, plus this change. The fixture was a physical iPhone 16 Pro Max running iOS 27.0 (24A435). The Mac app used isolated storage at `/tmp/intents-e2e-storage`; ordinary workspace data was not edited. All device runs were started with the Mac's Run scenario button.

## Scenarios and evidence

| Invocation | Scenario | Observed result |
|---|---|---|
| `BECC730E-8287-4A3A-9CD3-A29DA66DA2C5` | v1, correct note ID, three Siri attempts | Direct intent 1/1 and Siri 3/3 passed; all 8 assertions passed; release requirement accepted. |
| `FEB5C5F1-F591-4FDB-985A-E657E5006B6D` | v2, deliberately wrong note ID, one Siri attempt | Reproduced the harness bug: completed failed assertions caused XCTest exit 65 and an imported Needs review result. |
| `EF911625-3749-445B-A044-E866DE69B2E1` | v1, positive recheck with corrected harness | Direct intent 1/1 and Siri 3/3 passed; Mac imported Passed. |
| `BDCDFFC7-D043-4C20-8AD1-59194BEFFE19` | v2, negative recheck with corrected harness and Mac app | Mac imported Failed, both lanes retained actual `packing-001` against expected `packing-WRONG`, and release rejected the failed lanes/assertions. Device remained available. |

The successful scenario executes `OpenNoteIntent` and the recognized-text request “Open the packing note in Intent Lab Fixture.” It checks the selected stable ID `packing-001` and zero note-store mutations. The negative scenario changes the required expected ID only, with one Siri attempt to bound runtime.

Independent inspection of the first successful run verified the stopped/accepted journal; final envelope identity, nonce, digest and result-bundle binding; exact app and test executable SHA-256 hashes; four completed lane results; eight passed assertions; unique per-attempt contexts; and all three copied screenshot hashes and byte counts. The result bundle confirms the physical model/OS and single scenario test entry. The third-attempt screenshot was visually inspected and contains the expected note ID, zero mutation count, matching invocation context and `OpenNoteIntent:packing-001` event.

Saved evidence is under `/tmp/intents-e2e-storage/IntentLab/`:

- `Definitions/<scenario-id>/`: immutable versions and expectations.
- `Runs/F03D2846-DED8-4524-835A-F558B52772F1/<invocation>/run.json` and `Artifacts/`: imported results and screenshots.
- `Journals/<invocation>.json`: execution and evidence acceptance.
- `Executor/<invocation>/`: build/test log, exact signed products, result bundle, exported final/checkpoint envelopes.

These temporary artifacts are local verification evidence, not a distributed release. Their paths may be removed by later system cleanup.

## Findings fixed

1. **Completed assertion failure was misclassified as execution failure.** The harness now allows a completed failed result to finish evidence capture successfully. Empty, incomplete and unobserved results still fail the harness. The host's identity, journal, exit-status and release gates are unchanged; a failed required assertion still blocks release.
2. **Missing feature evidence was described as passing.** Diagnostic wording now requires actual completed passing feature-control evidence before attributing a failure to integration. The real negative report was inspected after rebuilding and uses the qualified wording when App feature is missing.
3. **A renamed newer version could restore an older draft.** Restoration now selects the latest version of the most recently run scenario. The rebuilt UI restored the negative v2 name and wrong expected value even after the most recent successful run used v1. With no run history, selection remains deterministic among latest versions.

The passing and failing reports were selected from persisted history after relaunch. The final Failed result also survived another close/reopen. Project build approval correctly reset between sessions. Test apps were closed at completion; no simulator was used.

## Regression verification

- Signed Mac `xcodebuild test`, scheme `FoundationEvals`, macOS destination, selected `IntentLabRegressionTests`, `ScenarioContractsTests`, and `MCPStoreAuthorityTests`: **65 tests passed**, zero failures. Result: `/tmp/intents-e2e-host-regressions.xcresult`.
- Physical signed fixture `xcodebuild test-without-building`, selected `testHarnessRetainsWrongVisibleResultAsFailureEvidence`, `testIncompleteOrUnobservedResultsFailTheHarness`, and `testSemanticAssertionIsHandedToHostForReview`: **3 tests passed**, zero failures. Result: `/tmp/intents-e2e-harness-regressions.xcresult`.
- `codesign --verify --deep --strict`: Mac app and exact device app, runner, and embedded test bundle verified with Apple Development signatures.
- `swiftc -frontend -parse` on changed Swift sources and `git diff --check`: passed.
- Independent scoped review found no material remaining issue and confirmed that failed scenarios cannot become release passes.

## Limits

This validates the integrated fixture's direct-intent and recognized-text Siri workflow, not arbitrary unintegrated applications, microphone speech recognition, or the optional production-feature lane. Other apps still need their own typed harness integration and valid signing.

On this iOS 27 runtime, Siri performs the action while XCTest reports activation timeouts. The existing narrowly matched recovery bridge preserves these as expected issues. Thus raw result bundles can say **Expected Failure** even when correlated final observations prove the scenario passed. That label alone is never accepted as proof: the final envelope and observed assertions were checked.

The envelope still records unknown host Xcode/SDK versions and a generic device model; the result bundle supplies the precise physical model/OS. Siri settings remain developer-declared. A signed/notarized release artifact was not produced or qualified by this validation.
