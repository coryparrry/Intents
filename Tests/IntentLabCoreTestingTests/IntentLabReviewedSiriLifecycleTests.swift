import Foundation
import IntentLabContracts
@testable import IntentLabCoreTesting
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabReviewedSiriLifecycleTests: XCTestCase {
    func testCapturedSiriProofSurvivesContextClearingCleanup() throws {
        let attempt = try capture()
        let lane = try attempt.action.get()
        XCTAssertTrue(attempt.integration.cleaned)
        XCTAssertFalse(attempt.integration.completed(observations: lane.observations, context: "captured"))
        XCTAssertNil(attempt.cleanupError)
        XCTAssertEqual(lane.outcome, .passed)
        XCTAssertTrue(lane.claims?.contains(.applicationStateChecked) == true)
    }

    func testCleanupFailureRemainsSeparateFromCapturedProof() throws {
        let attempt = try capture(cleanupFails: true)
        XCTAssertEqual(try attempt.action.get().outcome, .passed)
        XCTAssertNotNil(attempt.cleanupError)
    }

    func testMissingCompletionProofRemainsUnobserved() throws {
        let attempt = try capture(completion: false)
        XCTAssertEqual(try attempt.action.get().outcome, .notObserved)
        XCTAssertTrue(attempt.integration.cleaned)
    }

    private func capture(completion: Bool = true, cleanupFails: Bool = false) throws -> (
        action: Result<IntentLabLaneResult, Error>, cleanupError: Error?, integration: ContextIntegration
    ) {
        let scenarioJSON = """
        {"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000001","version":1,"name":"Captured state",
         "definitionDigest":"fixture","target":{"bundleIdentifier":"com.example.Fixture","projectPath":"Fixture.xcodeproj",
         "scheme":"Fixture","testTarget":"FixtureTests","destinationIdentifier":"device","route":"appIntentDefinition"},
         "goal":{"requestText":"Observe state","languageCode":"en","expectedBehavior":"State is complete"},
         "fixture":{"id":"fixture","version":"1","digest":"fixture","isSynthetic":true,
         "preparationOperation":"reset","cleanupOperation":"reset"},
         "directControl":{"intentIdentifier":"ObserveIntent","parameters":[],"outputFields":[]},
         "assertions":[{"id":"00000000-0000-0000-0000-000000000002","kind":"visibleText","observationKey":"state",
         "expectedValue":{"string":{"_0":"complete"}},"explanation":"Observed state","required":true}],
         "coverage":{"appFeature":"notApplicable","intentIntegration":"notApplicable","siri":"required","siriAttemptCount":1},
         "safety":{"mutationPolicy":"readOnly","allowedActions":[],"permittedConfirmationSteps":[],"deadlineSeconds":30},
         "purpose":"releaseRequirement","checkMode":"behaviour","requiredClaims":["executionCompleted","applicationStateChecked"],
         "observationPlan":[{"id":"state","source":"uiElement","selector":"state"}],
         "integration":{"id":"fixture","version":"1","digest":"fixture"}}
        """
        let declarationJSON = """
        {"schemaVersion":1,"id":"fixture","version":"1","targetBundleIdentifier":"com.example.Fixture",
         "projectIdentity":"Fixture.xcodeproj","targetIdentity":"FixtureTests","supportedHarnessProtocols":["intent-lab-v2"],
         "actions":[{"id":"ObserveIntent","parameters":[]}],"resultProjections":[],"preparationOperations":["reset"],
         "cleanupOperations":["reset"],"observers":[{"id":"state","source":"uiElement","selector":"state",
         "type":{"primitive":{"_0":"string"}}}],"isolation":{"kind":"synthetic"},
         "capabilities":["environment-payload","preparation","accessible-result","siri","siri-completion","invocation-correlation"]}
        """
        let scenario = try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: Data(scenarioJSON.utf8))
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self,
            from: Data(declarationJSON.utf8))
        try declaration.validate()
        let integration = ContextIntegration()
        integration.completionAvailable = completion
        let observations: [String: IntentLabValue] = ["state": .string("complete")]
        let attempt = IntentLabScenarioEngine.executeSiriAttempt(action: { observations }, evaluate: {
            IntentLabScenarioEngine.result(for: .siri, scenario: scenario, observations: $0,
                baseline: nil, integration: integration, declaration: declaration,
                context: "captured", startedAt: Date())
        }, cleanupRequired: { true }, skipCleanupAfter: { _ in false }, cleanup: {
            integration.cleaned = true
            if cleanupFails { throw TestError.cleanup }
        })
        return (attempt.action, attempt.cleanupError, integration)
    }

    private final class ContextIntegration: IntentLabSiriIntegration {
        var cleaned = false
        var completionAvailable = true
        var supportedCapabilities: Set<String> { ["preparation", "accessible-result", "siri", "siri-completion"] }
        func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
            throw TestError.noDevice
        }
        func observe(application: XCUIApplication) throws -> [String: IntentLabValue] { [:] }
        func completed(observations: [String: IntentLabValue], context: String) -> Bool {
            completionAvailable && !cleaned && context == "captured"
        }
    }

    private enum TestError: Error { case cleanup, noDevice }
}
