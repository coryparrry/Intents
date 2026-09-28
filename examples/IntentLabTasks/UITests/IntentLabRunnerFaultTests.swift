import CryptoKit
import Foundation
import IntentLabContracts
import IntentLabTesting
import XCTest

@available(iOS 27.0, *)
@MainActor
final class IntentLabRunnerFaultTests: XCTestCase {
    func testRunnerRejectsPlausibleSuccessWhenPersistenceIsSuppressed() throws {
        let (scenario, invocation) = try makeBehaviourScenario()
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: TaskIntegration(faultMode: "suppressPersistence"),
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        XCTAssertEqual(result.executionStatus, .completed)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.observations["completionResponse"] == .string("Completed Buy milk."))
        XCTAssertEqual(result.observations["task-001.isComplete"], .boolean(false))
        XCTAssertEqual(result.observations["task-002.isComplete"], .boolean(false))
        XCTAssertTrue(result.claims?.contains(.applicationStateChecked) ?? false)
        XCTAssertFalse(qualifiesForRelease(scenario: scenario, lane: result))
    }

    func testRunnerRejectsUnrelatedMutationEvenWithFreshReceipt() throws {
        let (scenario, invocation) = try makeBehaviourScenario()
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: TaskIntegration(faultMode: "mutateUnrelatedTask"),
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        XCTAssertEqual(result.observations["task-001.isComplete"], .boolean(true))
        XCTAssertEqual(result.observations["task-002.isComplete"], .boolean(true))
        XCTAssertNotNil(result.observations["actionReceiptID"])
        XCTAssertTrue(result.claims?.contains(.applicationStateChecked) ?? false)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertFalse(qualifiesForRelease(scenario: scenario, lane: result))
    }

    func testScopedUnchangedCheckRejectsMutationToExpectedConstant() throws {
        let (baseScenario, invocation) = try makeBehaviourScenario(expectedTaskTwoComplete: true)
        var scenario = baseScenario
        scenario.executionScope = .init(lane: .intentIntegration, attempt: 1)
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: TaskIntegration(faultMode: "mutateUnrelatedTask"),
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        let unchanged = try XCTUnwrap(scenario.assertions.first { $0.kind == .noMutation })
        XCTAssertEqual(result.beforeObservations?["task-002.isComplete"], .boolean(false))
        XCTAssertEqual(result.observations["task-002.isComplete"], .boolean(true))
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.assertionResults.contains {
            $0.assertionID == unchanged.id && !$0.passed
                && $0.message.contains("changed from its observed baseline")
        })
    }

    func testCorrectPersistentMutationQualifiesForRelease() throws {
        let (scenario, invocation) = try makeBehaviourScenario()
        let integration = TaskIntegration()
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: integration,
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        XCTAssertEqual(result.observations["task-001.isComplete"], .boolean(true))
        XCTAssertEqual(result.observations["task-002.isComplete"], .boolean(false))
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(integration.completedCleanups, 1)
        XCTAssertTrue(qualifiesForRelease(scenario: scenario, lane: result))
    }

    func testCleanupFailureInvalidatesOtherwisePassingDirectEvidence() throws {
        let (scenario, invocation) = try makeBehaviourScenario()
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: TaskIntegration(forceCleanupFailure: true),
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        XCTAssertEqual(result.executionStatus, .invalidEvidence)
        XCTAssertEqual(result.outcome, .notObserved)
        XCTAssertTrue(result.diagnostic?.contains("cleanup failed") ?? false)
        XCTAssertFalse(qualifiesForRelease(scenario: scenario, lane: result))
    }

    func testDirectBasicCheckVerifiesIntentOutputWithoutClaimingPersistence() throws {
        let (scenario, invocation) = try makeBehaviourScenario(checkMode: "basic")
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: TaskIntegration(),
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        XCTAssertEqual(result.observations["completionResponse"], .string("Completed Buy milk."))
        XCTAssertEqual(result.outcome, .passed)
        XCTAssertTrue(result.claims?.contains(.executionCompleted) ?? false)
        XCTAssertTrue(result.claims?.contains(.returnedValueChecked) ?? false)
        XCTAssertFalse(result.claims?.contains(.applicationStateChecked) ?? true)
    }

    func testWrongExpectedStateRetainsActualQueryAndFailsReleaseRequirement() throws {
        let (scenario, invocation) = try makeBehaviourScenario(expectedTaskOneComplete: false)
        let evidence = try IntentLabScenarioRunner.run(
            testCase: self,
            integration: TaskIntegration(),
            scenario: scenario,
            invocation: invocation
        )

        let result = try XCTUnwrap(evidence.results.first { $0.lane == .intentIntegration })
        XCTAssertEqual(result.observations["task-001.isComplete"], .boolean(true))
        XCTAssertEqual(result.observations["task-002.isComplete"], .boolean(false))
        XCTAssertTrue(result.claims?.contains(.applicationStateChecked) ?? false)
        let targetAssertion = try XCTUnwrap(scenario.assertions.first { $0.observationKey == "task-001.isComplete" })
        XCTAssertTrue(result.assertionResults.contains {
            $0.assertionID == targetAssertion.id && !$0.passed
        })
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertFalse(qualifiesForRelease(scenario: scenario, lane: result))
    }

    private func makeBehaviourScenario(
        checkMode: String = "behaviour",
        expectedTaskOneComplete: Bool = true,
        expectedTaskTwoComplete: Bool = false
    ) throws -> (IntentLabScenario, IntentLabInvocation) {
        let declarationURL = try XCTUnwrap(
            Bundle(for: TaskIntegration.self).url(forResource: "IntentLabIntegration", withExtension: "json")
        )
        let declarationData = try Data(contentsOf: declarationURL)
        let declaration = try JSONDecoder.intentLab.decode(IntentLabIntegrationDeclaration.self, from: declarationData)
        let integrationDigest = SHA256.hash(data: declarationData).map { String(format: "%02x", $0) }.joined()
        let integration: [String: Any] = [
            "id": declaration.id,
            "version": declaration.version,
            "digest": integrationDigest
        ]
        let definitionDigest = String(repeating: "c", count: 64)
        let targetBundleIdentifier = TaskIntegration.testingBundleIdentifier
        let observations: [[String: Any]] = [
            ["id": "task-001.isComplete", "source": "entityQuery", "operationID": "tasks-by-stable-id", "selector": "task-001.isComplete"],
            ["id": "task-002.isComplete", "source": "entityQuery", "operationID": "tasks-by-stable-id", "selector": "task-002.isComplete"]
        ]
        var assertions: [[String: Any]] = [
            ["id": UUID().uuidString, "kind": "returnedField", "observationKey": "completionResponse", "expectedValue": ["string": ["_0": "Completed Buy milk."]], "required": true, "applicableLanes": ["intentIntegration"]],
        ]
        if checkMode == "behaviour" {
            assertions.append(contentsOf: [
                ["id": UUID().uuidString, "kind": "stateTransition", "observationKey": "task-001.isComplete", "expectedValue": ["boolean": ["_0": expectedTaskOneComplete]], "required": true, "applicableLanes": ["intentIntegration"]],
                ["id": UUID().uuidString, "kind": "noMutation", "observationKey": "task-002.isComplete", "expectedValue": ["boolean": ["_0": expectedTaskTwoComplete]], "required": true, "applicableLanes": ["intentIntegration"]]
            ])
        }
        let requiredClaims = checkMode == "behaviour"
            ? ["executionCompleted", "returnedValueChecked", "applicationStateChecked"]
            : ["executionCompleted", "returnedValueChecked"]
        let purpose = checkMode == "behaviour" ? "releaseRequirement" : "exploratory"
        let scenarioID = UUID()
        let scenarioJSON: [String: Any] = [
            "schemaVersion": 2,
            "id": scenarioID.uuidString,
            "version": 1,
            "definitionDigest": definitionDigest,
            "target": ["bundleIdentifier": targetBundleIdentifier],
            "goal": ["requestText": "Complete Buy milk in Intent Lab Tasks", "languageCode": "en"],
            "fixture": ["id": "task-fixture", "version": "1", "digest": String(repeating: "d", count: 64), "preparationOperation": TaskIntegration.preparationOperation, "cleanupOperation": TaskIntegration.cleanupOperation],
            "directControl": [
                "intentIdentifier": "CompleteTaskIntent",
                "parameters": [[
                    "name": "task",
                    "type": ["entity": ["typeIdentifier": "TaskEntity"]],
                    "isOptional": false,
                    "presence": ["value": ["_0": ["entity": ["_0": ["typeIdentifier": "TaskEntity", "identifier": "task-001"]]]]]
                ]],
                "outputFields": [[
                    "name": "completionResponse",
                    "type": ["primitive": ["_0": "string"]],
                    "path": [["kind": "property", "name": "value"]]
                ]]
            ],
            "assertions": assertions,
            "coverage": ["appFeature": "notApplicable", "intentIntegration": "required", "siri": "notApplicable"],
            "safety": ["deadlineSeconds": 30],
            "purpose": purpose,
            "checkMode": checkMode,
            "requiredClaims": requiredClaims,
            "observationPlan": checkMode == "behaviour" ? observations : [],
            "integration": integration
        ]
        let scenario = try JSONDecoder.intentLab.decode(
            IntentLabScenario.self,
            from: JSONSerialization.data(withJSONObject: scenarioJSON)
        )
        let invocationID = UUID()
        let productHash = String(repeating: "a", count: 64)
        let invocationJSON: [String: Any] = [
            "id": invocationID.uuidString,
            "nonce": UUID().uuidString,
            "issuedAt": ISO8601DateFormatter().string(from: Date()),
            "testIdentity": ["bundleIdentifier": "com.example.IntentLabTasksUITests", "className": "IntentLabRunnerFaultTests", "methodName": "testFaultScenario"],
            "harnessVersion": "intent-lab-v2",
            "destinationIdentifier": "intent-lab-tasks-test",
            "scenarioDigest": definitionDigest,
            "resultBundleIdentity": UUID().uuidString,
            "appProduct": ["bundleIdentifier": targetBundleIdentifier, "executableName": "IntentLabTasks", "sha256": productHash],
            "testProduct": ["bundleIdentifier": "com.example.IntentLabTasksUITests", "executableName": "IntentLabTasksUITests", "sha256": productHash],
            "integration": integration,
            "requiredCapabilities": declaration.capabilities
        ]
        let invocation = try JSONDecoder.intentLab.decode(
            IntentLabInvocation.self,
            from: JSONSerialization.data(withJSONObject: invocationJSON)
        )
        try scenario.validateContract(harnessVersion: invocation.harnessVersion)
        return (scenario, invocation)
    }

    /// Portable equivalent for this UI-test target: required runner claims and every
    /// required deterministic assertion must pass before a result can satisfy release.
    private func qualifiesForRelease(scenario: IntentLabScenario, lane: IntentLabLaneResult) -> Bool {
        guard scenario.purpose == .releaseRequirement,
              scenario.checkMode == .behaviour,
              lane.lane == .intentIntegration,
              lane.executionStatus == .completed,
              lane.outcome == .passed,
              let claims = lane.claims,
              (scenario.requiredClaims ?? []).allSatisfy(claims.contains) else {
            return false
        }

        let required = scenario.assertions.filter {
            $0.required && ($0.applicableLanes?.contains(.intentIntegration) ?? true)
        }
        return required.allSatisfy { assertion in
            lane.assertionResults.contains {
                $0.assertionID == assertion.id && $0.passed
            }
        }
    }
}
