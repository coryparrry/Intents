import Foundation
import IntentLabContracts
import XCTest

final class SiriResultCaptureTests: XCTestCase {
    func testSiriStateProofSurvivesCleanupResettingAdapterContextAndReceipt() throws {
        let integration = ResettingIntegration()
        let scenario = try makeScenario()
        let declaration = try makeDeclaration()
        let observations = integration.observations
        let artifact = IntentLabArtifactReference(
            id: UUID(), kind: "screenshot", filename: "siri-result.png",
            relativePath: "siri-result.png", contentType: "image/png",
            byteCount: 1, sha256: String(repeating: "a", count: 64), manuallySupplied: false
        )
        XCTAssertTrue(integration.completed(observations: observations, context: "attempt"))

        let attempt = IntentLabAttemptLifecycle.execute {
            IntentLabResultCapture.capture(
                for: .siri, scenario: scenario, observations: observations, baseline: nil,
                completion: { integration.completed(observations: observations, context: "attempt") },
                source: { integration.source(for: $0) }, declaration: declaration, startedAt: Date(),
                attempt: 2, artifacts: [artifact]
            )
        } cleanupRequired: {
            true
        } cleanup: {
            try integration.cleanup(bundleIdentifier: "com.example.App", context: "attempt", operationID: "reset")
        }

        XCTAssertNil(attempt.cleanupError)
        XCTAssertFalse(integration.completed(observations: observations, context: "attempt"))
        let result = try attempt.action.get()
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(result.claims, [.executionCompleted, .applicationStateChecked])
        XCTAssertEqual(result.observations, observations)
        XCTAssertEqual(result.observationSources?["invocationContext"], "accessibleUI")
        XCTAssertEqual(result.artifacts.map(\.id), [artifact.id])
        XCTAssertEqual(result.attempt, 2)
        // This is the pre-fix ordering: evaluating the same receipt after reset
        // loses application state proof even though the action completed.
        let afterCleanup = IntentLabResultCapture.capture(
            for: .siri, scenario: scenario, observations: observations, baseline: nil,
            completion: { integration.completed(observations: observations, context: "attempt") },
            source: { integration.source(for: $0) }, declaration: declaration, startedAt: Date(),
            attempt: 2, artifacts: []
        )
        XCTAssertEqual(afterCleanup.outcome, .notObserved)
        XCTAssertEqual(afterCleanup.claims, [.executionCompleted])
    }

    func testSiriResultWithoutFreshReceiptCannotClaimApplicationState() throws {
        let integration = ResettingIntegration()
        var observations = integration.observations
        observations["actionReceiptID"] = .string("")
        let result = IntentLabResultCapture.capture(
            for: .siri, scenario: try makeScenario(), observations: observations, baseline: nil,
            completion: { integration.completed(observations: observations, context: "attempt") },
            source: { integration.source(for: $0) }, declaration: try makeDeclaration(), startedAt: Date(),
            attempt: 1, artifacts: []
        )
        XCTAssertEqual(result.outcome, .notObserved)
        XCTAssertEqual(result.claims, [.executionCompleted])
    }

    func testFreshSiriCompletionRetainsWrongStateAsFailedAssertion() throws {
        let integration = ResettingIntegration()
        var observations = integration.observations
        observations["task.isComplete"] = .boolean(false)
        let result = IntentLabResultCapture.capture(
            for: .siri, scenario: try makeScenario(), observations: observations, baseline: nil,
            completion: { integration.completed(observations: observations, context: "attempt") },
            source: { integration.source(for: $0) }, declaration: try makeDeclaration(), startedAt: Date(),
            attempt: 1, artifacts: []
        )
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.claims, [.executionCompleted, .applicationStateChecked])
        XCTAssertEqual(result.assertionResults.map(\.passed), [false])
        XCTAssertEqual(result.assertionResults.first?.observedValue, .boolean(false))
    }

    private func makeScenario() throws -> IntentLabScenario {
        try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: Data("""
        {
          "schemaVersion":2,"id":"00000000-0000-0000-0000-000000000001","version":1,
          "definitionDigest":"frozen","target":{"bundleIdentifier":"com.example.App"},
          "goal":{"requestText":"Complete the task","languageCode":"en-GB"},
          "fixture":{"id":"tasks","version":"1","digest":"fixture","preparationOperation":"prepare","cleanupOperation":"reset"},
          "directControl":{"intentIdentifier":"CompleteTaskIntent","parameters":[],"outputFields":[]},
          "assertions":[{"id":"00000000-0000-0000-0000-000000000002","kind":"stateTransition","observationKey":"task.isComplete","expectedValue":{"boolean":{"_0":true}},"required":true}],
          "coverage":{"appFeature":"notApplicable","intentIntegration":"required","siri":"required","siriAttemptCount":2},
          "safety":{"deadlineSeconds":10,"mutationPolicy":"syntheticMutation"},
          "purpose":"releaseRequirement","checkMode":"behaviour",
          "requiredClaims":["executionCompleted","applicationStateChecked"],
          "observationPlan":[{"id":"task.isComplete","source":"entityQuery","operationID":"tasks"}],
          "integration":{"id":"tasks","version":"1","digest":"frozen"}
        }
        """.utf8))
    }

    private func makeDeclaration() throws -> IntentLabIntegrationDeclaration {
        try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: Data("""
        {
          "schemaVersion":1,"id":"tasks","version":"1","targetBundleIdentifier":"com.example.App",
          "projectIdentity":"App.xcodeproj","targetIdentity":"AppUITests","supportedHarnessProtocols":["intent-lab-v2"],
          "actions":[],"resultProjections":[],"preparationOperations":["prepare"],"cleanupOperations":["reset"],
          "observers":[{"id":"task.isComplete","source":"entityQuery","type":{"primitive":{"_0":"boolean"}},"operationID":"tasks"}],
          "queryOperations":[{"id":"tasks","source":"entityQuery","typeIdentifier":"Task","identifiers":["task"]}],
          "isolation":{"kind":"synthetic"},"capabilities":[]
        }
        """.utf8))
    }
}

private final class ResettingIntegration {
    private var activeContext: String? = "attempt"
    private var receipt: String? = "fresh-receipt"
    var observations: [String: IntentLabValue] {
        ["task.isComplete": .boolean(true), "invocationContext": .string("attempt"),
         "actionReceiptID": .string("fresh-receipt")]
    }

    func cleanup(bundleIdentifier: String, context: String, operationID: String) throws {
        activeContext = nil
        receipt = nil
    }

    func completed(observations: [String: IntentLabValue], context: String) -> Bool {
        guard let receipt, !receipt.isEmpty else { return false }
        return activeContext == context
            && observations["invocationContext"] == .string(context)
            && observations["actionReceiptID"] == .string(receipt)
    }

    func source(for observationKey: String) -> String {
        activeContext == nil ? "reset" : "accessibleUI"
    }

}
