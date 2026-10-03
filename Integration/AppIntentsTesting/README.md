# Intent Lab iOS UI-test integration

The repository-root Swift package publishes `IntentLabContracts`, `IntentLabTesting`, and `IntentLabCoreTesting`. Add `IntentLabTesting` to an iOS 27 UI-test target signed with the same development team as the application when the check invokes an App Intent directly, uses a project-local Feature control, or reads an App Entity/value query. Add `IntentLabContracts` explicitly when the consumer adapter imports its value and declaration types. The UI-test target owns the fixed XCTest entry point; the package owns invocation, evidence capture, Siri handling, and typed result projections. `SiriActivationBridge` is packaged internally, so do not add a bridging header or copy the legacy source files in this directory. Those files remain here only as the v1 source-integration reference.

For stable v3 checks, the default Feature backend is a project-local test control. Your app implements one small support surface for synthetic fixture preparation, feature invocation through its actual production service, independent state read-back, cleanup, and a harmless readiness operation. The generated test-only intent transports those operations; it does not decide success. Record bounded `IntentLabActionReceipt` values at production Intent/service entry, including the actual operation, resolved parameters, outcome, attempt context, and app session. The host compares these receipts with the frozen action requirement and the independently observed state. A missing, stale, or different action cannot pass because its final state happens to look right. The Notes and Tasks examples show distinct app-owned implementations. A connected developer runner remains an explicit alternative backend, not a second mandatory pairing step.

For a Siri-only coordinate, a separate UI-test target can depend on `IntentLabCoreTesting` without loading Apple's `AppIntentsTesting` framework. Its adapter conforms to `IntentLabSiriIntegration` and calls `IntentLabSiriScenarioRunner.run(testCase:integration:)` and `.checkConnection(testCase:integration:)`. Give this target its own `IntentLabIntegration.json` with its exact target identity and only the capabilities it implements. The core rejects a direct Intent lane or an entity/value query observation before preparing the app. A required query therefore remains blocked until a compatible `AppIntentsTesting` runner can execute it; UI observations cannot stand in for declared query evidence. The Notes sample's `IntentLabFixtureSiri` scheme shows the separate target and declaration.

XCTest can launch the app and submit recognized Siri text automatically on a paired, unlocked physical iPhone. Unlock and system consent are device prerequisites, not steps to substitute with manual feature taps or spoken Siri requests. The runner requires a fresh prepared context and independently observed completion before accepting a Siri result. A Siri activation timeout alone is not a passing result.

A direct-only read-only Basic integration can start with:

```swift
import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabScenarioTests: XCTestCase {
    func testIntentLabScenario() throws {
        try IntentLabScenarioRunner.run(testCase: self, integration: IntentLabBasicIntegration())
    }

    func testIntentLabConnection() throws {
        try IntentLabScenarioRunner.checkConnection(testCase: self, integration: IntentLabBasicIntegration())
    }
}
```

Bundle `IntentLabIntegration.json` with this test target. The minimum read-only declaration is:

```json
{"schemaVersion":1,"id":"com.example.app.intentlab","version":"1","targetBundleIdentifier":"com.example.app","projectIdentity":"Example.xcodeproj","targetIdentity":"ExampleUITests","supportedHarnessProtocols":["intent-lab-v2"],"actions":[{"id":"KnownIntentIdentifier","parameters":[]}],"resultProjections":[],"preparationOperations":["none"],"observers":[],"isolation":{"kind":"readOnly"},"capabilities":["environment-payload","direct-intent-execution"]}
```

The host freezes the declaration identity (`id`, `version`, SHA-256 of the exact JSON file bytes) into the v2 scenario and invocation. `testIntentLabConnection` attaches a read-only `IntentLabConnectionReceipt-<UUID>.json`. It never prepares data or runs the business intent. Host setup must bind that receipt to the exact built app and test products and recheck it after integration changes. The scenario method validates the same identity and required capabilities before execution. v1 scenarios use the original protocol and evidence schema.

For Behaviour checks, replace `IntentLabBasicIntegration` with an app-owned `IntentLabIntegration` adapter. Its `prepare` method allowlists the declared operation, establishes isolated data, and launches the app. `observe` reads actual state without receiving expected values. `completed` checks the current attempt context plus a fresh independent action receipt. `cleanup` must allowlist a declared cleanup operation, restore the isolated data, and verify its postcondition; cleanup failure invalidates the attempt. `source(for:)` reports each observation's actual provenance (`accessibleUI`, `entityQuery`, `valueQuery`, or `testOnlyIntent`). Declare the same observation IDs, sources, preparation and cleanup operations, and selectors in `IntentLabIntegration.json`. An operation ID names compiled adapter code; it is never an arbitrary script. The notes example in `examples/IntentLabFixture/UITests` shows a UI-backed adapter.

Add `testIntentLabReadiness` to each stable v3 UI-test target. It checks app launch, observer availability, and declared test support without invoking the business action. The connection check binds its typed receipt to the selected app/test products, declaration, source, runtime, and destination. Route status is shown separately: a Siri-only Core target can be ready to attempt when Direct or local Feature is blocked by AppIntentsTesting. The readiness result does not prove Siri selected the intended production action. A connection or readiness test that fails to load leaves that route blocked; it is not a passing scenario result.

For project-local Feature support, declare the control's feature ID, operation ID, typed input mapping, output projections, `local-feature-controls`, and `test-only-intent` capability. Put the support intent and adapter behind development-only build conditions and confirm they are absent from the Release product. The app receives business inputs and correlation context, not the expected answer. Its observed `intentlab.fixtureDigest` must come from fixture content or persisted read-back, not from the expected digest in the test. Preserve the same frozen declaration, fixture, action, measurements, and backend when comparing failed and corrected app builds. Use **Check this fix** for selected diagnostic routes, then **Verify complete requirement** for all required routes and attempts; a partial diagnostic cannot qualify the full requirement.

For an existing App Entity query, declare `"queryOperations":[{"id":"tasks-by-stable-id","source":"entityQuery","typeIdentifier":"TaskEntity","identifiers":["task-001","task-002"]}]` and typed observers such as `{"id":"task-001.isComplete","source":"entityQuery","type":{"primitive":{"_0":"boolean"}},"operationID":"tasks-by-stable-id","selector":"task-001.isComplete"}`. Mark each projected entity field with AppIntents `@Property(title:)`; a plain stored field can resolve as `NSNull` through `AnyAppEntity` even when the entity query succeeds. The package reads the declared IDs through `IntentDefinitions`, rejects missing or duplicate entities, and bounds the query wait. A value query uses the same operation ID pattern with `source:"valueQuery"`, its query type identifier, and a typed `input` value. The shared runner merges generic query results with any app-owned observations and rejects conflicting values. It checks a before/after state transition for direct Behaviour when the adapter has no completion receipt; unchanged old success cannot qualify as a fresh state change.

A completed assertion mismatch is a failed scenario, not a failed evidence-capture process. The harness attaches the final failed result and allows XCTest to finish successfully; the host still rejects that scenario for release. Incomplete or unobserved execution continues to fail XCTest and requires recovery.

The harness resets and relaunches the synthetic fixture between the direct-intent and Siri lanes. Siri completion requires the declared visible state or a state transition, and a failure stores a checksummed screenshot alongside the JSON envelope. The Basic example above declares no Feature control, so it cannot satisfy required App Feature coverage.
An `id` selector reads the stable entity identifier directly.

Output projection paths start with `{"kind":"property","name":"value"}` and may continue with public `DynamicPropertyPath` properties or indexes. String, Boolean, integer, finite number, date, enum, entity-reference, and homogeneous-array projections are supported. Invalid or unsupported conversions fail explicitly. A direct returned value does not prove persisted state. `returnedValueChecked` applies to direct execution; Siri requires fresh completion and observed state. `XCUISiriService.activate(voiceRecognitionText:)` tests recognised text, not microphone recognition. The package reports v2 claims and provenance per lane; release qualification still belongs to the host report gate. XCTest may finish capture successfully for a failed scenario.

After the Mac app imports a scenario run, use `script/foundation-evals scenario-report --run-id <uuid>` as the CI release gate. The app and its MCP connector must be running. This command reads the same authoritative release check shown by the app and MCP report; it exits zero only for `passed` and nonzero for failed, incomplete, or incompatible evidence. A green `xcodebuild test` result alone means evidence capture completed, not that the required outcome passed.

The package release identifier, harness protocol (`intent-lab-v2`), declaration schema (1), scenario schema (2), and evidence schema (2) are separate values. `0.2.0-dev` identifies this unreleased package state; pin consumers to a real repository revision for review. The package preserves the repository's existing macOS/iOS 26 platform floors, while the runner APIs require iOS 27. The supplied Basic integration supports only read-only direct checks with no state proof; unsupported preparation fails clearly. A signed physical iPhone remains required for Siri qualification.
