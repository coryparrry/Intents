# Intent Lab iOS UI-test integration

The repository-root Swift package publishes `IntentLabContracts` and `IntentLabTesting`. Add `IntentLabTesting` to an iOS 27 UI-test target signed with the same development team as the application. Add `IntentLabContracts` explicitly when the consumer adapter imports its value and declaration types. The UI-test target owns the fixed XCTest entry point; the package owns invocation, evidence capture, Siri handling, and typed result projections. `SiriActivationBridge` is packaged internally, so do not add a bridging header or copy the legacy source files in this directory. Those files remain here only as the v1 source-integration reference.

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

For Behaviour checks, replace `IntentLabBasicIntegration` with an app-owned `IntentLabIntegration` adapter. Its `prepare` method allowlists the declared operation, establishes isolated data, and launches the app. `observe` reads actual state without receiving expected values. `completed` checks the current attempt context plus a fresh independent action receipt. `source(for:)` reports each observation's actual provenance (`accessibleUI`, `entityQuery`, `valueQuery`, or `testOnlyIntent`). Declare the same observation IDs, sources, operation IDs, and selectors in `IntentLabIntegration.json`. An operation ID names compiled adapter code; it is never an arbitrary script. The notes example in `examples/IntentLabFixture/UITests` shows a UI-backed adapter.

For an existing App Entity query, declare `"queryOperations":[{"id":"tasks-by-stable-id","source":"entityQuery","typeIdentifier":"TaskEntity","identifiers":["task-001","task-002"]}]` and typed observers such as `{"id":"task-001.isComplete","source":"entityQuery","type":{"primitive":{"_0":"boolean"}},"operationID":"tasks-by-stable-id","selector":"task-001.isComplete"}`. Mark each projected entity field with AppIntents `@Property(title:)`; a plain stored field can resolve as `NSNull` through `AnyAppEntity` even when the entity query succeeds. The package reads the declared IDs through `IntentDefinitions`, rejects missing or duplicate entities, and bounds the query wait. A value query uses the same operation ID pattern with `source:"valueQuery"`, its query type identifier, and a typed `input` value. The shared runner merges generic query results with any app-owned observations and rejects conflicting values. It checks a before/after state transition for direct Behaviour when the adapter has no completion receipt; unchanged old success cannot qualify as a fresh state change.

A completed assertion mismatch is a failed scenario, not a failed evidence-capture process. The harness attaches the final failed result and allows XCTest to finish successfully; the host still rejects that scenario for release. Incomplete or unobserved execution continues to fail XCTest and requires recovery.

The harness resets and relaunches the synthetic fixture between the direct-intent and Siri lanes. Siri completion requires the declared visible state or a state transition, and a failure stores a checksummed screenshot alongside the JSON envelope. Required App Feature coverage is intentionally rejected by desktop preflight because this UI-test bundle only owns Intent Integration and Siri evidence.
An `id` selector reads the stable entity identifier directly.

Output projection paths start with `{"kind":"property","name":"value"}` and may continue with public `DynamicPropertyPath` properties or indexes. String, Boolean, integer, finite number, date, enum, entity-reference, and homogeneous-array projections are supported. Invalid or unsupported conversions fail explicitly. A direct returned value does not prove persisted state. `returnedValueChecked` applies to direct execution; Siri requires fresh completion and observed state. `XCUISiriService.activate(voiceRecognitionText:)` tests recognised text, not microphone recognition. The package reports v2 claims and provenance per lane; release qualification still belongs to the host report gate. XCTest may finish capture successfully for a failed scenario.

After the Mac app imports a scenario run, use `script/foundation-evals scenario-report --run-id <uuid>` as the CI release gate. The app and its MCP connector must be running. This command reads the same authoritative release check shown by the app and MCP report; it exits zero only for `passed` and nonzero for failed, incomplete, or incompatible evidence. A green `xcodebuild test` result alone means evidence capture completed, not that the required outcome passed.

The package release identifier, harness protocol (`intent-lab-v2`), declaration schema (1), scenario schema (2), and evidence schema (2) are separate values. `0.2.0-dev` identifies this unreleased package state; pin consumers to a real repository revision for review. The package preserves the repository's existing macOS/iOS 26 platform floors, while the runner APIs require iOS 27. The supplied Basic integration supports only read-only direct checks with no state proof; unsupported preparation fails clearly. A signed physical iPhone remains required for Siri qualification.
