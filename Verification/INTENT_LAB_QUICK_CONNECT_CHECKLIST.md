# Intent Lab Quick Connect implementation checklist

The normal device workflow must be:

1. Choose an Xcode project or workspace.
2. Choose a connected iPhone by name.
3. Approve Build and Run.
4. Run the scenario.

Manual identifiers remain available only as advanced overrides.

## Phase 1 — single-build invocation transport

- [x] Build the selected scheme exactly once with `build-for-testing`.
- [x] Resolve the app, UI-test runner, and test bundle from the generated `.xctestrun`.
- [x] Bind host-computed product fingerprints to the fresh invocation.
- [x] Create an invocation-specific sibling `.xctestrun` so `__TESTROOT__` remains valid.
- [x] Inject the frozen scenario and invocation into the UI-test runner environment.
- [x] Preserve Xcode-owned environment and testing-environment entries.
- [x] Support current flat and `TestConfigurations` `.xctestrun` layouts.
- [x] Reject partial, stale, malformed, mismatched, or oversized environment payloads.
- [x] Keep bundled JSON loading only when neither environment payload is present.
- [x] Ensure payload contents are not written to Intent Lab logs or shared reports; crash leftovers are removed during journal recovery.
- [x] Compile the environment loader inside the fixture UI-test bundle.
- [ ] Prove the transport on the paired physical iPhone — blocked because the sample app and UI-test targets do not have a development team; Intent Lab now reports this as a distinct signing requirement.

## Phase 2 — Quick Connect

- [x] Add a native project/workspace chooser.
- [x] Discover schemes, app products, UI-test targets, and bundle identifiers for projects and referenced workspace projects.
- [x] Automatically select a unique compatible scheme/target pair.
- [x] Show a concise choice when discovery is ambiguous.
- [x] Discover paired physical iPhones and display them by name.
- [x] Persist stable selection identifiers while refreshing live availability.
- [x] Replace the trust toggle with an explicit Build and Run confirmation.
- [x] Persist the resolved connection profile without persisting approval.
- [x] Move raw identifiers and paths under Advanced.
- [x] Migrate previously saved execution configuration.

## Phase 3 — guided harness setup

- [x] Detect the expected harness identity and version through explicit UI-test target build settings.
- [x] Report missing signing, fixture reset, invocation correlation, accessibility, payload, and intent-output capabilities separately.
- [x] Provide precise setup instructions when the selected target is not compatible.
- [x] Do not silently mutate signing or project configuration.
- [ ] Keep any future installer previewable, idempotent, and reversible — no installer is included in this implementation.

## Phase 4 — recovery

- [x] Keep interrupted or cancelled device sessions quarantined.
- [ ] Clear quarantine automatically only with invocation-correlated termination and fixture-readiness evidence — automatic clearing is intentionally not implemented; ambiguous sessions remain quarantined.
- [x] Retain manual recovery for crashes, disconnects, and ambiguous termination.
- [x] Cover cancellation, timeout policy, relaunch, explicit recovery, and private payload cleanup with regression tests.

## Acceptance

- [ ] A compatible signed project reaches Run without typed paths, scheme, target, bundle ID, generated-resource directory, or UDID — implemented, but the included fixture cannot complete this live gate until a development team is selected.
- [x] The UI describes the device by name and never silently substitutes another destination.
- [x] One build occurs per invocation.
- [x] Subsequent runs reuse the saved project/device selection while approval resets on relaunch.
- [x] Ambiguity and missing integration produce specific next actions.
- [x] Product identities are described as host-bound provenance, not device attestation.

## Verification record

- [x] `swift test --scratch-path /tmp/foundation-evals-quick-connect --filter ScenarioContractsTests` — 21 tests passed.
- [x] Focused `FoundationEvalsCoreCI` Xcode run — 24 tests passed across `ScenarioContractsTests` and `IntentLabRegressionTests`.
- [x] Unsigned generic-iOS fixture `build-for-testing` — succeeded, including the UI-test harness.
- [x] Final macOS UI inspection — the project, named-device, approval, and Run steps render as one four-step card; the live device picker lists `iPhone`.
- [ ] Signed physical-iPhone fixture build — stopped at Xcode provisioning because both fixture targets require a development team.
