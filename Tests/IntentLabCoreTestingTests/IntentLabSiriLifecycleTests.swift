import Foundation
import IntentLabContracts
@testable import IntentLabCoreTesting
import XCTest

@available(macOS 27.0, iOS 27.0, *)
@MainActor
final class IntentLabSiriLifecycleTests: XCTestCase {
    func testCompletedSiriStateIsEvaluatedBeforeCleanupClearsTheContext() throws {
        let attempt = try capture()
        let lane = try attempt.action.get()
        XCTAssertTrue(attempt.integration.cleaned)
        XCTAssertNil(attempt.cleanupError)
        XCTAssertFalse(attempt.integration.completed(observations: lane.observations, context: "siri-current"))
        XCTAssertEqual(lane.outcome, .passed)
        XCTAssertTrue(lane.claims?.contains(.applicationStateChecked) == true)
        XCTAssertTrue(lane.assertionResults.allSatisfy(\.passed))
        XCTAssertEqual(lane.beforeObservations?["presented"], .boolean(false))
        XCTAssertEqual(lane.observations["presented"], .boolean(true))
        XCTAssertEqual(IntentLabScenarioEngine.cleanupVerification(
            required: true, cleanupError: attempt.cleanupError, cleanupWasSkipped: false), true)
    }

    func testCleanupFailureRemainsSeparateFromVerifiedCapturedState() throws {
        let attempt = try capture(cleanupFails: true)
        let lane = try attempt.action.get()
        XCTAssertEqual(lane.outcome, .passed)
        XCTAssertTrue(lane.claims?.contains(.applicationStateChecked) == true)
        XCTAssertNotNil(attempt.cleanupError)
        XCTAssertEqual(IntentLabScenarioEngine.cleanupVerification(
            required: true, cleanupError: attempt.cleanupError, cleanupWasSkipped: false), false)
    }

    func testSiriCaptureDoesNotPromoteMissingWrongDuplicateOrFailedActions() throws {
        for fault in ["missing", "wrong", "duplicate", "failed", "stale"] {
            let attempt = try capture(fault: fault)
            XCTAssertNotEqual(try attempt.action.get().outcome, .passed, fault)
            XCTAssertTrue(attempt.integration.cleaned, fault)
        }
    }

    func testIncompleteConsumerCompletionDoesNotClaimCheckedApplicationState() throws {
        let attempt = try capture(fault: "incomplete")
        let lane = try attempt.action.get()
        XCTAssertEqual(lane.outcome, .notObserved)
        XCTAssertFalse(lane.claims?.contains(.applicationStateChecked) == true)
        XCTAssertTrue(attempt.integration.cleaned)
    }

    func testSiriActionErrorStillCleansUpWithoutEvaluatingState() throws {
        let integration = ContextIntegration()
        var evaluated = false
        let attempt = IntentLabScenarioEngine.executeSiriAttempt(action: {
            throw TestError.action
        }, evaluate: { _ in
            evaluated = true
            XCTFail("An incomplete action cannot be evaluated as captured state")
            return .init(caseID: UUID(), attempt: 1, lane: .siri, executionStatus: .completed,
                         outcome: .passed, startedAt: Date(), completedAt: Date(), observations: [:],
                         assertionResults: [], diagnostic: nil, proposedCause: nil, artifacts: [])
        }, cleanupRequired: { true }, skipCleanupAfter: { _ in false }, cleanup: {
            integration.cleaned = true
        })
        XCTAssertThrowsError(try attempt.action.get())
        XCTAssertFalse(evaluated)
        XCTAssertTrue(integration.cleaned)
    }

    private func capture(fault: String = "none", cleanupFails: Bool = false) throws -> (
        action: Result<IntentLabLaneResult, Error>, cleanupError: Error?, integration: ContextIntegration
    ) {
        let integration = ContextIntegration()
        integration.completionAvailable = fault != "incomplete"
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "id": UUID().uuidString, "version": 1,
            "definitionDigest": String(repeating: "a", count: 64),
            "target": ["bundleIdentifier": "com.example.Lifecycle"],
            "goal": ["requestText": "Open an item", "languageCode": "en"],
            "fixture": ["id": "test", "version": "1", "digest": String(repeating: "b", count: 64),
                        "preparationOperation": "prepare", "cleanupOperation": "cleanup"],
            "directControl": ["intentIdentifier": "OpenItem", "parameters": [], "outputFields": []],
            "assertions": [],
            "coverage": ["appFeature": "notApplicable", "intentIntegration": "notApplicable", "siri": "required"],
            "safety": ["deadlineSeconds": 5]
        ])
        var scenario = try JSONDecoder.intentLab.decode(IntentLabScenario.self, from: data)
        scenario.schemaVersion = 2
        scenario.requiredClaims = [.executionCompleted, .applicationStateChecked]
        scenario.executionScope = .init(lane: .siri, attempt: 1)
        scenario.assertions = [
            .init(id: UUID(), kind: .stateTransition, observationKey: "presented", expectedValue: .boolean(true), required: true, applicableLanes: [.siri]),
            .init(id: UUID(), kind: .noMutation, observationKey: "rows", expectedValue: .string("fixture"), required: true, applicableLanes: [.siri])
        ]
        scenario.observationPlan = try JSONDecoder.intentLab.decode([IntentLabPlannedObservation].self,
            from: JSONSerialization.data(withJSONObject: [
                ["id": "presented", "source": "uiElement", "selector": "presented"],
                ["id": "rows", "source": "uiElement", "selector": "rows"]
            ]))
        scenario.actionRequirements = [.init(lane: .siri, kind: .productionIntent,
            operationID: "OpenItem", resolvedParameters: [:])]
        let declarationData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "id": "test", "version": "1", "targetBundleIdentifier": "com.example.Lifecycle",
            "projectIdentity": "test", "targetIdentity": "test", "supportedHarnessProtocols": ["intent-lab-v2"],
            "actions": [], "resultProjections": [], "preparationOperations": [],
            "observers": [
                ["id": "presented", "source": "uiElement", "type": ["primitive": ["_0": "boolean"]]],
                ["id": "rows", "source": "uiElement", "type": ["primitive": ["_0": "string"]]]
            ], "isolation": ["kind": "synthetic"], "capabilities": []
        ])
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: declarationData)
        let start = Date(timeIntervalSince1970: 10)
        var receipt = IntentLabActionReceipt(executionID: UUID(), appSessionID: UUID(),
            attemptContext: fault == "stale" ? "siri-old" : "siri-current", lane: .siri, attempt: 1,
            kind: .productionIntent, operationID: fault == "wrong" ? "OtherItem" : "OpenItem", resolvedParameters: [:],
            terminalStatus: fault == "failed" ? .failed : .succeeded,
            operationError: fault == "failed" ? "operation failed" : nil,
            sequence: 1, startedAt: start, completedAt: start.addingTimeInterval(1), observationTransport: "accessibleUI")
        var receipts = fault == "missing" ? [] : [receipt]
        if fault == "duplicate" { receipt.executionID = UUID(); receipt.sequence = 2; receipts.append(receipt) }
        let raw = String(decoding: try JSONEncoder.intentLab.encode(receipts), as: UTF8.self)
        let observations: [String: IntentLabValue] = ["presented": .boolean(true), "rows": .string("fixture"),
            "intentlab.actionReceipts": .string(raw)]
        let attempt = IntentLabScenarioEngine.executeSiriAttempt(action: { observations }, evaluate: {
            IntentLabScenarioEngine.result(for: .siri, scenario: scenario, observations: $0,
                baseline: ["presented": .boolean(false), "rows": .string("fixture")],
                integration: integration, declaration: declaration, context: "siri-current", startedAt: start)
        }, cleanupRequired: { true }, skipCleanupAfter: { _ in false }, cleanup: {
            integration.cleaned = true
            if cleanupFails { throw TestError.cleanup }
        })
        return (attempt.action, attempt.cleanupError, integration)
    }

    private final class ContextIntegration: IntentLabSiriIntegration {
        var cleaned = false
        var completionAvailable = true
        var supportedCapabilities: Set<String> { [] }
        func prepare(bundleIdentifier: String, context: String, operationID: String) throws -> XCUIApplication {
            XCTFail("No app or device is used by this regression")
            return XCUIApplication()
        }
        func cleanup(bundleIdentifier: String, context: String, operationID: String) throws { cleaned = true }
        func observe(application: XCUIApplication) throws -> [String: IntentLabValue] { [:] }
        func completed(observations: [String: IntentLabValue], context: String) -> Bool { completionAvailable && !cleaned && context == "siri-current" }
    }
    private enum TestError: Error { case action, cleanup }
}
